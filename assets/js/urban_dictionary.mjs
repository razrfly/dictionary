// Urban Dictionary, fetched by the reader's browser and never stored (#136).
//
// The GIPHY shelf's shape applied to a definition instead of a rail: the server
// renders a shell it cannot fill, this fills it from the reader's own browser,
// and nothing survives the visit. There is no `localStorage`, no
// `sessionStorage`, no cache and no retry anywhere below — only the request
// accounting, which lives in module scope so a reader walking twenty word pages
// cannot spend twenty budgets, and which holds counters rather than content.
//
// Anything that is not exactly the measured envelope removes the section from
// the DOM and says nothing. A card that cannot be trusted is worse than no
// card, and a crowd definition the reader did not ask for is not worth an
// error message.
const attempts = []
let retryAt = 0

// One definition per word page, so an hour of ordinary reading is well inside
// this. It exists for the pathological case — a script, a stuck reload — and
// it is the same courtesy GIPHY's pays to a service whose rate limit is
// unpublished.
const BUDGET = 60
const WINDOW_MS = 3600_000

export function retryDelay(value, now = Date.now()) {
  if (value && /^\d+$/.test(value)) return Number(value) * 1000
  const date = Date.parse(value)
  return Number.isFinite(date) ? Math.max(0, date - now) : 60_000
}

// The Elixir side is `DevilsDictionary.Registry.Lexeme.slug/1`, which is
// `Slug.slugify/1` with the downcased lemma as its fallback. The two rules are
// held together by `assets/js/slug_cases.json`, which both test suites read:
// see that file's note for the range this reproduces and the range it does not.
const LIGATURES = {
  'ß': 'ss', 'æ': 'ae', 'Æ': 'ae', 'œ': 'oe', 'Œ': 'oe',
  'þ': 'th', 'Þ': 'th', 'ð': 'd', 'Ð': 'd',
  'ø': 'o', 'Ø': 'o', 'ł': 'l', 'Ł': 'l'
}

export function slugify(text) {
  const source = String(text ?? '')
  const slug = [...source]
    .map(character => LIGATURES[character] ?? character)
    .join('')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    // Removed rather than separated, exactly as `Slug.slugify/1` does it, so
    // `don't` is `dont` and not `don-t`.
    .replace(/['`’]/g, '')
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean)
    .join('-')
  // A lemma that is all punctuation (`++`) has no slug at all; the downcased
  // lemma is what the Elixir fallback gives it and what its URL really is.
  return slug || source.toLowerCase()
}

// Whether an entry's `word` is this page's term. Case, accents and the choice
// of space or hyphen are not a different word (`Mother-In-Law` is
// `mother-in-law`); punctuation is (`C` is not `C++`), which is why this is
// not the slug rule — both slug to `c` (CodeRabbit on the #136 PR).
export function sameWord(a, b) {
  const fold = value => String(value ?? '')
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[\s_-]+/g, ' ')
    .trim()
  return fold(a) === fold(b) && fold(a) !== ''
}

export function defineURL(term, endpoint) {
  if (!term || [...term].length > 64) throw new Error('term')
  const url = new URL(endpoint)
  if (url.protocol !== 'https:') throw new Error('endpoint')
  url.search = new URLSearchParams({term})
  return url.href
}

function permalink(value, host) {
  try {
    const url = new URL(value)
    return url.protocol === 'https:' && !url.username && !url.password &&
      (url.hostname === host || url.hostname.endsWith(`.${host.replace(/^www\./, '')}`))
      ? url.href
      : null
  } catch { return null }
}

// The envelope, as measured on 2026-09-21, and nothing else accepted.
//
// Two things here are not in the issue and were measured on the way. The first
// is that `/v0/define` **fuzzy-matches**: `logomachy` answers 200 with two
// entries, for `Logomashup` and `logomancy`. An unknown term is therefore not
// reliably `{"list": []}`, and a card that trusted the status code would put a
// definition of another word under this word's headword. So the entry's own
// `word` has to slug to the same slug as the term, and `logomachy` is the
// honest empty because of this check rather than in spite of it. The second is
// that `thumbs_up` and `thumbs_down` are 0 on every entry, which is why they
// are neither ranked on nor read: the list order is the site's own and the
// first entry is the one it puts first.
export function parseDefinition(body, term) {
  if (!body || !Array.isArray(body.list) || body.list.length > 10) throw new Error('envelope')
  const mine = body.list.filter(entry =>
    entry && typeof entry.word === 'string' && sameWord(entry.word, term))
  if (mine.length === 0) return null
  const entry = mine[0]
  const written = Date.parse(entry.written_on)
  const url = permalink(entry.permalink, 'www.urbandictionary.com')
  if (!Number.isInteger(entry.defid) || typeof entry.definition !== 'string' ||
      typeof entry.author !== 'string' || !entry.definition.trim() ||
      !Number.isFinite(written) || !url) throw new Error('entry')
  return {
    defid: entry.defid,
    word: entry.word,
    definition: entry.definition,
    example: typeof entry.example === 'string' ? entry.example : '',
    author: entry.author,
    writtenOn: new Date(written),
    permalink: url,
    total: mine.length
  }
}

// `[bracketed]` is Urban Dictionary's own cross-link syntax, and turning it
// into a link to *our* `/define/<slug>` is the one thing this card can do that
// the site cannot. Returned as a list of parts rather than as HTML: nothing
// below ever builds markup from a string, so a definition containing `<script>`
// is a definition containing the eleven characters `<script>`.
export function parseLinks(text) {
  const parts = []
  const pattern = /\[([^[\]\n]+)\]/g
  let at = 0
  let match
  while ((match = pattern.exec(text)) !== null) {
    if (match.index > at) parts.push({text: text.slice(at, match.index)})
    parts.push({text: match[1], slug: slugify(match[1])})
    at = match.index + match[0].length
  }
  if (at < text.length) parts.push({text: text.slice(at)})
  return parts
}

export function formatDate(date) {
  return new Intl.DateTimeFormat('en-GB', {day: 'numeric', month: 'long', year: 'numeric'})
    .format(date)
}

export default {
  mounted() {
    this.alive = true
    this.load()
  },

  async load() {
    const now = Date.now()
    while (attempts.length && attempts[0] <= now - WINDOW_MS) attempts.shift()
    // A paused budget is not an error the reader needs told about: this card is
    // an extra, so it simply is not there.
    if (retryAt > now || attempts.length >= BUDGET) return this.retire()

    this.controller = new AbortController()
    const timer = setTimeout(() => this.controller.abort(), 8_000)
    try {
      const {term, endpoint} = this.el.dataset
      attempts.push(now)
      const response = await globalThis.fetch(defineURL(term, endpoint), {
        signal: this.controller.signal,
        credentials: 'omit',
        cache: 'no-store',
        referrerPolicy: 'no-referrer'
      })
      if (response.status === 429) {
        retryAt = Date.now() + Math.max(1000, retryDelay(response.headers.get('Retry-After')))
        throw new Error('paused')
      }
      if (!response.ok) throw new Error('http')
      const definition = parseDefinition(await response.json(), term)
      if (!this.alive) return
      // An empty list, or ten entries for a word that is not this one.
      if (!definition) return this.retire()
      this.render(definition)
    } catch {
      // Deliberately silent and deliberately not retried. Every failure — the
      // network, the timeout, a changed envelope, a fuzzy match — has the same
      // answer, which is that the page is the page it was without this card.
      this.retire()
    } finally {
      clearTimeout(timer)
    }
  },

  // Removed, not hidden: a shell nobody filled is chrome making a promise the
  // card did not keep.
  retire() {
    this.el.remove()
  },

  render(definition) {
    const body = this.el.querySelector('[data-body]')
    const definePath = this.el.dataset.definePath

    body.append(this.prose(definition.definition, definePath, 'definition'))
    if (definition.example.trim()) {
      body.append(this.prose(definition.example, definePath, 'example'))
    }

    const byline = document.createElement('p')
    byline.className = 'mt-4 text-sm text-mist-500'
    byline.textContent = `by ${definition.author} · ${formatDate(definition.writtenOn)}`

    const out = document.createElement('a')
    out.href = definition.permalink
    out.target = '_blank'
    out.rel = 'noreferrer noopener'
    out.className = 'underline underline-offset-4 hover:text-mist-950 dark:hover:text-white'
    out.textContent = 'Read on Urban Dictionary'
    const outLine = document.createElement('p')
    outLine.className = 'mt-2 text-sm text-mist-500'
    outLine.append(out)

    const plaque = this.el.querySelector('[data-plaque]')
    plaque.textContent =
      'Crowd-sourced and unreviewed. ' +
      `One of ${definition.total} ${definition.total === 1 ? 'entry' : 'entries'} on ` +
      `Urban Dictionary, by ${definition.author}, ${formatDate(definition.writtenOn)}. ` +
      'Fetched by your browser; nothing is stored here.'

    body.append(byline, outLine)
    this.el.querySelector('[data-status]')?.remove()
  },

  prose(text, definePath, kind) {
    const p = document.createElement('p')
    p.className = kind === 'example'
      ? 'mt-4 border-l-2 border-mist-950/10 pl-4 whitespace-pre-line text-mist-500 italic dark:border-white/10'
      : 'mt-4 whitespace-pre-line'
    p.dataset[kind] = ''
    for (const part of parseLinks(text)) {
      if (part.slug) {
        const link = document.createElement('a')
        link.href = `${definePath}/${encodeURIComponent(part.slug)}`
        link.className = 'underline underline-offset-4 hover:text-amber-700'
        link.textContent = part.text
        p.append(link)
      } else {
        p.append(document.createTextNode(part.text))
      }
    }
    return p
  },

  destroyed() {
    this.alive = false
    this.controller?.abort()
  }
}
