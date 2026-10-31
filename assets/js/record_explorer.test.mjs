import test from "node:test"
import assert from "node:assert/strict"
import {matchesRecord, applyFilters, records, openRecordTarget, recordText, categoryCounts, interleave, excerpt, recordTargetId, updateCategoryButtons, defaultLayout, selectedLayout, replaceResults, revealRecordFragment, filterURL, adoptExplorerState} from "./record_explorer.mjs"

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
test("filtering leaves complete source records untouched and clearing restores the index", () => {
  const quote = row("cordial love · Milton", "quote", "wiktionary")
  const definition = row("An affectionate feeling. cordial love · Milton", "definition", "wiktionary", [quote.node])
  const unrelated = row("A tennis score", "definition", "wordnet")
  const rows = [definition, quote, unrelated]
  assert.equal(applyFilters(rows, {type: "quote", q: "Milton"}).length, 1)
  assert.equal(definition.node.hidden, false)
  assert.equal(quote.node.hidden, false)
  assert.equal(unrelated.node.hidden, false)
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
  assert.equal(earlier.node.hidden, false)
  assert.equal(news.node.hidden, false)
  applyFilters(rows, {q: "not-present"})
  assert.equal(applyFilters(rows, {q: "not-present"}).length, 0)
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


test("definition search excludes quotation payload while quotation keeps source context", () => {
  const text = value => ({nodeType: 3, textContent: value})
  const element = (children, nested = false) => ({
    nodeType: 1, childNodes: children,
    hasAttribute(name) { return nested && name === "data-record-kind" }
  })
  const definition = element([text("Affection."), element([text("cordial love · Milton")], true)])
  assert.equal(recordText(definition).trim(), "Affection.")
  assert.equal(matchesRecord(row(recordText(definition), "definition", "wiktionary"),
    {q: "Milton", type: "definition"}), false)
})

test("category counts respect search and source, independently of the selected category", () => {
 const rows = [row("love", "artwork", "met"), row("love", "news", "guardian"), row("war", "news", "guardian")]
 assert.equal(categoryCounts(rows, {q:"love", type:"news"})[""], 2)
 assert.equal(categoryCounts(rows, {q:"love", type:"news"}).artwork, 1)
 assert.equal(categoryCounts(rows, {source:"guardian"}).news, 2)
 assert.equal(categoryCounts(rows, {source:"missing"})[""], 0)
})
test("mixed results expose each category early without dropping observations", () => {
 const rows = [row("one", "quote", "a"), row("two", "quote", "b"), row("image", "image", "c"), row("news", "news", "d")]
 assert.deepEqual(interleave(rows).map(row => row.text), ["one", "image", "news", "two"])
 assert.equal(rows.length, 4)
})

test("a long native record shows context around a search match, as plain text", () => {
 const text = "prefix ".repeat(100) + "Milton <script>" + " suffix".repeat(100)
 assert.ok(excerpt(text, "Milton").includes("Milton <script>"))
 assert.ok(excerpt(text, "Milton").length <= 362)
})

test("search finds all words in any order across a material record", () => {
 const record = row("Jacques-Louis David · Erasistratus · 1774", "artwork", "wikidata")
 assert.ok(matchesRecord(record, {q: "1774 David"}))
 assert.equal(matchesRecord(record, {q: "1774 Picasso"}), false)
})

test("browser record targets stay unique after arrivals or withdrawals shift row positions", () => {
 const occupied = new Set(["material-record-1"])
 const dom = {getElementById: id => occupied.has(id)}
 const first = {id: ""}
 const firstId = recordTargetId(first, dom)
 assert.equal(occupied.has(firstId), false)
 occupied.add(firstId)
 const later = {id: ""}
 const laterId = recordTargetId(later, dom)
 assert.notEqual(firstId, laterId)
 assert.equal(recordTargetId(first, dom), firstId)
 assert.equal(recordTargetId({id: "card-bierce"}, dom), "card-bierce")
})

test("category updates keep the same button nodes for keyboard focus", () => {
 const children = []
 const container = {append: button => children.push(button)}
 const create = () => ({dataset: {}, attributes: {}, setAttribute(name, value) {this.attributes[name] = value}})
 const buttons = updateCategoryButtons(container, new Map(), categoryCounts([], {}), "", create)
 const artwork = buttons.get("artwork")
 const all = buttons.get("")
 const count = children.length
 updateCategoryButtons(container, buttons, categoryCounts([row("love", "artwork", "met")], {}), "artwork", create)
 assert.equal(buttons.get("artwork"), artwork)
 assert.equal(buttons.get(""), all)
 assert.equal(children.length, count)
 assert.equal(artwork.attributes["aria-pressed"], "true")
 assert.equal(artwork.textContent, "Artworks 1")
})


test("visual categories start in grid while mixed and reading categories start in list", () => {
  for (const kind of ["artwork", "image", "film", "gif"]) assert.equal(defaultLayout(kind), "grid")
  for (const kind of ["", "definition", "quote", "example", "text", "news", "music", "entity", "word", "related"]) assert.equal(defaultLayout(kind), "list")
})
test("layout choice is remembered per category without changing other defaults", () => {
  const choices = new Map([["gif", "list"], ["definition", "grid"]])
  assert.equal(selectedLayout("gif", choices), "list")
  assert.equal(selectedLayout("definition", choices), "grid")
  assert.equal(selectedLayout("image", choices), "grid")
  assert.equal(selectedLayout("", choices), "list")
})


function focusFixture() {
  const doc = {activeElement: null}
  const makeRow = (target, open = false) => {
    const details = {open}
    const result = {dataset: {materialTarget: target}, querySelector: () => details}
    const link = {tagName: "A", textContent: "Complete record", getAttribute: () => "#" + target,
      closest: () => result, focus: () => {doc.activeElement = link}}
    result.querySelectorAll = () => [link]
    return {result, details, link}
  }
  const old = makeRow("first", true)
  let rows = [old.result]
  const container = {ownerDocument: doc, contains: el => el === old.link,
    querySelectorAll: () => rows, replaceChildren: (...nodes) => {rows = nodes; doc.activeElement = null}}
  return {doc, makeRow, old, container}
}
test("late results preserve focused links and open details using fresh eligible nodes", () => {
  const {doc, makeRow, old, container} = focusFixture()
  doc.activeElement = old.link
  const updated = makeRow("first")
  const arrived = makeRow("later")
  replaceResults(container, [updated.result, arrived.result])
  assert.equal(doc.activeElement, updated.link)
  assert.equal(updated.details.open, true)
  assert.equal(arrived.details.open, false)
  assert.notEqual(updated.result, old.result)
})
test("withdrawn focused results move focus to search instead of retaining their payload", () => {
  const {doc, makeRow, old, container} = focusFixture()
  const search = {focus: () => {doc.activeElement = search}}
  doc.activeElement = old.link
  replaceResults(container, [makeRow("later").result], search)
  assert.equal(doc.activeElement, search)
})


test("an asynchronous fragment is revealed once and later updates do not steal scroll", () => {
  const state = {}
  let target = null, scrolls = 0
  const inventory = {contains: node => node === target}
  const dom = {getElementById: () => target}
  revealRecordFragment(state, inventory, "#late", dom)
  assert.equal(state.pendingFragment, "late")
  target = {tagName: "DETAILS", parentElement: inventory, open: false, scrollIntoView: () => {scrolls++}}
  revealRecordFragment(state, inventory, "#late", dom)
  assert.equal(target.open, true)
  assert.equal(state.pendingFragment, null)
  assert.equal(scrolls, 1)
  revealRecordFragment(state, inventory, "#late", dom)
  assert.equal(scrolls, 1)
  revealRecordFragment(state, inventory, "#%broken", dom)
  assert.equal(state.pendingFragment, null)
})


test("filter URLs keep the clean resource path and drop empty controls without losing identity", () => {
  assert.equal(filterURL('https://example.test/on/love/materials', {}), '/on/love/materials')
  const filtered = filterURL('https://example.test/words/42/love/materials?trail=war', {q: 'David 1774', type: 'artwork', source: 'met'})
  const url = new URL(filtered, 'https://example.test')
  assert.equal(url.pathname, '/words/42/love/materials')
  assert.equal(url.searchParams.get('q'), 'David 1774')
  assert.equal(url.searchParams.get('trail'), 'war')
  assert.equal(filterURL(url.href, {}), '/words/42/love/materials?trail=war')
})


test("the live hook adopts early category nodes without duplicates or losing layout choices", () => {
  const children = []
  const container = {append: button => children.push(button)}
  const create = () => ({dataset: {}, setAttribute() {}})
  const el = {}
  const early = {el, categoryButtons: updateCategoryButtons(container, new Map(), categoryCounts([], {}), "", create),
    layoutChoices: new Map([["definition", "grid"]]), limit: 60, revealedHash: "#card-bierce"}
  const count = children.length
  const live = {el}
  adoptExplorerState(live, early)
  updateCategoryButtons(container, live.categoryButtons, categoryCounts([], {}), "definition", create)
  assert.equal(children.length, count)
  assert.equal(live.categoryButtons, early.categoryButtons)
  assert.equal(selectedLayout("definition", live.layoutChoices), "grid")
  assert.equal(live.limit, 60)
  const otherPage = {el: {}}
  adoptExplorerState(otherPage, early)
  assert.equal(otherPage.categoryButtons, undefined)
})
