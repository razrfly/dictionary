import test from "node:test"
import assert from "node:assert/strict"
import {matchesRecord, applyFilters, records, openRecordTarget} from "./record_explorer.mjs"

const node = (children = []) => ({
  hidden: false,
  contains(other) { return children.includes(other) }
})
const row = (text, type, source, children = []) =>
  ({node: node(children), text, type, sources: [{id: source, label: source}]})

test("search combines Unicode text, content type and exact source identity", () => {
  const record = row("Érasistratus · Jacques-Louis David · 1774", "artwork", "wikidata")
  assert.ok(matchesRecord(record, {q: "erasistratus", type: "artwork", source: "wikidata"}))
  assert.equal(matchesRecord(record, {q: "love", type: "artwork"}), false)
  assert.equal(matchesRecord(record, {type: "news"}), false)
  assert.equal(matchesRecord(record, {source: "met"}), false)
})
test("quotation matches preserve their source context; clearing restores every record", () => {
  const quote = row("cordial love · Milton", "quote", "wiktionary")
  const definition = row("An affectionate feeling. cordial love · Milton", "definition", "wiktionary", [quote.node])
  const unrelated = row("A tennis score", "definition", "wordnet")
  const rows = [definition, quote, unrelated]
  assert.equal(applyFilters(rows, {type: "quote", q: "Milton"}).length, 1)
  assert.equal(definition.node.hidden, false)
  assert.equal(quote.node.hidden, false)
  assert.equal(unrelated.node.hidden, true)
  applyFilters(rows, {})
  assert.ok(rows.every(record => !record.node.hidden))
})
test("a later arriving result obeys the active filters without losing any row", () => {
  const earlier = row("Love under sunset", "image", "pexels")
  const rows = [earlier]
  applyFilters(rows, {type: "news"})
  const news = row("New study of affection", "news", "guardian")
  rows.push(news)
  assert.deepEqual(applyFilters(rows, {type: "news"}), [news])
  assert.equal(earlier.node.hidden, true)
  assert.equal(news.node.hidden, false)
  applyFilters(rows, {q: "not-present"})
  assert.ok(rows.every(record => record.node.hidden))
  applyFilters(rows, {})
  assert.ok(rows.every(record => !record.node.hidden))
})
test("browser-only rows inherit the actual provider and type without being saved", () => {
  const gif = {textContent: "Cat Love GIF"}
  const shelf = {
    dataset: {recordKind: "gif", recordSources: JSON.stringify([{id: "giphy", label: "GIPHY"}])},
    querySelectorAll() { return [gif] }
  }
  const inventory = {querySelectorAll(selector) {
    return selector === "[data-record-browser]" ? [shelf] : []
  }}
  const [record] = records(inventory)
  assert.equal(record.node, gif)
  assert.ok(matchesRecord(record, {q: "cat", source: "giphy", type: "gif"}))
  assert.equal(matchesRecord(record, {source: "guardian"}), false)
})


test("an exact source target opens its record and containing disclosures only", () => {
  const inventory = {contains(target) { return target === quote }}
  const card = {tagName: "DETAILS", open: false, parentElement: inventory}
  const more = {tagName: "DETAILS", open: false, parentElement: card}
  const quote = {tagName: "LI", parentElement: more}
  assert.equal(openRecordTarget(inventory, quote), true)
  assert.equal(card.open, true)
  assert.equal(more.open, true)
  assert.equal(openRecordTarget(inventory, {tagName: "DETAILS", open: false}), false)
  assert.equal(openRecordTarget(inventory, null), false)
})
