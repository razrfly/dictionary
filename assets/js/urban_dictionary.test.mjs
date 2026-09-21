import test from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import Hook, {
  defineURL, slugify, sameWord, parseDefinition, parseLinks, formatDate, retryDelay
} from './urban_dictionary.mjs'

// The one response captured from the live site (2026-09-21, `term=cromulent`,
// with the signed, expiring audio URLs dropped). Nothing else in this PR comes
// from Urban Dictionary's servers, and nothing in the suite makes a request.
const SAMPLE = JSON.parse(readFileSync(new URL('./urban_dictionary.sample.json', import.meta.url)))
const CASES = JSON.parse(readFileSync(new URL('./slug_cases.json', import.meta.url))).cases

test('the slug rule agrees with Lexeme.slug/1 on every shared case', () => {
  // The Elixir half of this is
  // test/devils_dictionary/sources/urban_dictionary_slug_test.exs, reading the
  // same file. A rule that drifts fails on both sides at once.
  for (const {from, to} of CASES) {
    assert.equal(slugify(from), to, `slugify(${JSON.stringify(from)})`)
  }
  assert.ok(CASES.length >= 30, 'the shared case list should not quietly shrink')
})

test('the captured response parses to its first matching entry', () => {
  const entry = parseDefinition(SAMPLE, 'cromulent')
  assert.equal(entry.defid, 60071)
  assert.equal(entry.word, 'Cromulent')
  assert.equal(entry.author, 'Bradley Yeats, Professor of Linguistics')
  assert.equal(entry.permalink, 'https://www.urbandictionary.com/define.php?term=Cromulent&defid=60071')
  assert.equal(formatDate(entry.writtenOn), '15 March 2003')
  // Ten entries came back; three of them are `Cromulent Fuckcrustable`,
  // `Corpulent` and `corpulent brony`, which are not this word. The plaque
  // counts what the site holds *for this word*.
  assert.equal(SAMPLE.list.length, 10)
  assert.equal(entry.total, 7)
})

test('votes are read from nothing: the API returns zeroes and the card shows none', () => {
  for (const item of SAMPLE.list) {
    assert.equal(item.thumbs_up, 0)
    assert.equal(item.thumbs_down, 0)
  }
  const entry = parseDefinition(SAMPLE, 'cromulent')
  assert.ok(!('thumbs_up' in entry) && !('thumbs_down' in entry))
})

test('an empty list is no card, not an error', () => {
  assert.equal(parseDefinition({list: []}, 'qqzzxwvpluffnarg'), null)
})

test('a fuzzy match for another word is no card: /v0/define answers near-misses', () => {
  // Measured 2026-09-21: `term=logomachy` answers 200 with `Logomashup` and
  // `logomancy`. Without this guard the page would put a definition of another
  // word under this word's headword.
  const logomachy = {list: [
    {defid: 4837048, word: 'Logomashup', definition: 'a [mashup]', example: '', author: "David C'",
     written_on: '2010-03-27T00:00:00.000Z',
     permalink: 'https://www.urbandictionary.com/define.php?term=Logomashup&defid=4837048'},
    {defid: 5, word: 'logomancy', definition: 'divination', example: '', author: 'a',
     written_on: '2010-03-27T00:00:00.000Z',
     permalink: 'https://www.urbandictionary.com/define.php?term=logomancy&defid=5'}
  ]}
  assert.equal(parseDefinition(logomachy, 'logomachy'), null)
  assert.ok(parseDefinition(logomachy, 'Logomashup'))
})

test('case and punctuation differences are still this word', () => {
  const list = {list: [{defid: 1, word: 'Mother-In-Law', definition: 'd', example: '', author: 'a',
    written_on: '2020-01-02T00:00:00.000Z',
    permalink: 'https://www.urbandictionary.com/define.php?term=x&defid=1'}]}
  assert.equal(parseDefinition(list, 'mother-in-law').defid, 1)
})

test('punctuation is part of the word: an entry for C is not the term C++', () => {
  const c = {defid: 2, word: 'C', definition: 'a language', example: '', author: 'a',
    written_on: '2020-01-02T00:00:00.000Z',
    permalink: 'https://www.urbandictionary.com/define.php?term=C&defid=2'}
  assert.equal(parseDefinition({list: [c]}, 'C++'), null)
  assert.equal(parseDefinition({list: [{...c, word: 'c++'}]}, 'C++').defid, 2)
  assert.ok(sameWord('Mother In Law', 'mother-in-law'))
  assert.ok(!sameWord('', ''))
})

test('a malformed envelope or entry throws rather than rendering', () => {
  const ok = SAMPLE.list[0]
  const with_ = extra => ({list: [{...ok, ...extra}]})
  assert.throws(() => parseDefinition(null, 'cromulent'), /envelope/)
  assert.throws(() => parseDefinition({}, 'cromulent'), /envelope/)
  assert.throws(() => parseDefinition({list: 'no'}, 'cromulent'), /envelope/)
  assert.throws(() => parseDefinition({list: Array(11).fill(ok)}, 'cromulent'), /envelope/)
  assert.throws(() => parseDefinition(with_({defid: '60071'}), 'cromulent'), /entry/)
  assert.throws(() => parseDefinition(with_({definition: '   '}), 'cromulent'), /entry/)
  assert.throws(() => parseDefinition(with_({written_on: 'never'}), 'cromulent'), /entry/)
  assert.throws(() => parseDefinition(with_({author: 12}), 'cromulent'), /entry/)
})

test('a permalink off Urban Dictionary, or not https, is refused', () => {
  const ok = SAMPLE.list[0]
  for (const permalink of [
    'javascript:alert(1)',
    'http://www.urbandictionary.com/define.php?term=x',
    'https://evil.example/define.php?term=x',
    'https://user:pw@www.urbandictionary.com/x',
    'https://www.urbandictionary.com.evil.example/x'
  ]) {
    assert.throws(() => parseDefinition({list: [{...ok, permalink}]}, 'cromulent'), /entry/, permalink)
  }
})

test('bracketed cross-links become our own slugs, and the rest stays text', () => {
  const parts = parseLinks('[Sexual intercourse] between a [human] and a real, *non-[human]* animal.')
  assert.deepEqual(parts.filter(p => p.slug).map(p => p.slug),
    ['sexual-intercourse', 'human', 'human'])
  assert.equal(parts.map(p => p.text).join(''),
    'Sexual intercourse between a human and a real, *non-human* animal.')
})

test('unmatched, empty and multi-line brackets are left as text', () => {
  assert.deepEqual(parseLinks('a [b'), [{text: 'a [b'}])
  assert.deepEqual(parseLinks('[]'), [{text: '[]'}])
  assert.deepEqual(parseLinks('[a\nb]'), [{text: '[a\nb]'}])
  assert.deepEqual(parseLinks('{curly} stays'), [{text: '{curly} stays'}])
})

test('the request is one GET to the measured endpoint with the exact term', () => {
  const url = new URL(defineURL('mother-in-law', 'https://api.urbandictionary.com/v0/define'))
  assert.equal(url.origin + url.pathname, 'https://api.urbandictionary.com/v0/define')
  assert.equal(url.searchParams.get('term'), 'mother-in-law')
  assert.equal([...url.searchParams.keys()].length, 1, 'no key, no options, nothing else')
  assert.throws(() => defineURL('', 'https://api.urbandictionary.com/v0/define'))
  assert.throws(() => defineURL('x'.repeat(65), 'https://api.urbandictionary.com/v0/define'))
  assert.throws(() => defineURL('x', 'http://api.urbandictionary.com/v0/define'), /endpoint/)
})

test('Retry-After is parsed conservatively', () => {
  assert.equal(retryDelay('120'), 120000)
  assert.equal(retryDelay(null), 60000)
  assert.equal(retryDelay('Thu, 01 Jan 1970 00:01:00 GMT', 0), 60000)
})

// ── the hook, against a stub element ──────────────────────────────────────

function context(term = 'cromulent') {
  let removed = false
  return {
    alive: true,
    retire: Hook.retire,
    render: Hook.render,
    removed: () => removed,
    el: {
      dataset: {term, endpoint: 'https://api.urbandictionary.com/v0/define', definePath: '/define'},
      remove() { removed = true },
      querySelector() { return null }
    }
  }
}

async function withFetch(impl, fn) {
  const old = globalThis.fetch
  globalThis.fetch = impl
  try { return await fn() } finally { globalThis.fetch = old }
}

test('a network failure removes the section and does not retry', async () => {
  let calls = 0
  const ctx = context()
  await withFetch(async () => { calls++; throw new TypeError('network') },
    () => Hook.load.call(ctx))
  assert.equal(calls, 1)
  assert.ok(ctx.removed())
})

test('a 500 removes the section silently', async () => {
  const ctx = context()
  await withFetch(async () => ({ok: false, status: 500}), () => Hook.load.call(ctx))
  assert.ok(ctx.removed())
})

test('an empty list removes the section', async () => {
  const ctx = context('qqzzxwvpluffnarg')
  await withFetch(async () => ({ok: true, status: 200, json: async () => ({list: []})}),
    () => Hook.load.call(ctx))
  assert.ok(ctx.removed())
})

test('a response arriving after navigation renders nothing', async () => {
  let release
  const ctx = context()
  await withFetch(() => new Promise(resolve => { release = resolve }), async () => {
    const pending = Hook.load.call(ctx)
    ctx.alive = false
    release({ok: true, status: 200, json: async () => SAMPLE})
    await pending
  })
  assert.ok(!ctx.removed(), 'a dead hook neither renders nor tears down a replaced element')
})

test('a 429 pauses the next page view without another request', async () => {
  let calls = 0
  const first = context()
  const second = context()
  await withFetch(async () => { calls++; return {status: 429, headers: {get: () => '60'}} },
    async () => {
      await Hook.load.call(first)
      await Hook.load.call(second)
    })
  assert.equal(calls, 1, 'the cool-down is module-wide, not per element')
  assert.ok(first.removed() && second.removed())
})

test('nothing is written to browser storage', () => {
  // Comments stripped first: this asserts about the code, not about the prose
  // that explains the code, and the prose has to be free to name what it
  // promises never to call.
  const code = readFileSync(new URL('./urban_dictionary.mjs', import.meta.url), 'utf8')
    .replace(/^\s*\/\/.*$/gm, '')
  for (const forbidden of ['localStorage', 'sessionStorage', 'indexedDB', 'document.cookie', 'caches']) {
    assert.ok(!code.includes(forbidden), `urban_dictionary.mjs must not call ${forbidden}`)
  }
  assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML/.test(code),
    'the card is built from nodes and textContent, never from a markup string')
})
