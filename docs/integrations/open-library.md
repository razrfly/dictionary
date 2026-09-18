# Open Library

**#109 Phase 3c, 2026-09-18.** Both archetypes: a discovery provider matching
by attestation over Open Library's full-text search, and `open-library-v1`, a
committed corpus of 946 public-domain literary works keyed on the same
identifier. It is the first corpus registered end to end through
`mix dd.provider.new`'s printout.

---

## The spec — the four decisions

| Decision | Value |
|---|---|
| archetype | **both** |
| content type | `:text` — the *Texts* shelf, beside PoetryDB's poems |
| transport | GET |
| pagination | offset |
| identity | `olid` — the Open Library **work** id (`OL267171W`) |
| match | attestation (K11): `search/inside.json` proposes, the snippet disposes at a word boundary |
| corpus identity | `olid`, `work_kind: "book"`, `evidence: :none` |
| pacing | `request_interval_ms` 1,000 · `min_retry_interval_ms` 5,000 |
| ceiling | **300 requests**, across Open Library and the Wikidata Query Service together |

The identity is the point of the phase. A book found live and a book held in
the manifest resolve to **one** registry entity, because both write `olid`.

---

## The ledger

Running totals, as the guide's §1 requires. Every request used `Req` and the
shared contact `User-Agent`, which is what Open Library asks for. **No cover
image bytes were downloaded at any point** — cover URLs only, and only where
Open Library published an id to build one from.

### Part 1 — Open Library and the Internet Archive (17 requests)

| # | Request | Result |
|---|---|---|
| 1 | `search/inside.json?q=war` | **200**, 6.7 s — 20 docs, Internet Archive ids, `{{{war}}}` snippets |
| 2 | `search.json?q=ia:resorttowardatag0000sark` | **200** — `numFound: 0` |
| 3 | `archive.org/metadata/resorttowardatag0000sark` | **200**, 4.2 s — `openlibrary_work: OL16946778W` |
| 4 | `search.json?q=ocaid:…` | transport **timeout** at 5.1 s |
| 5 | `search.json?q=ocaid:(a OR b OR c)` | **200** — `numFound: 0`; `ocaid` is not queryable |
| 6 | `search.json?q=war&fields=…` | **200** — work keys `/works/OL…W` and an `ia` list |
| 7 | `search.json?q=ia:artofwaroldestmi00suntuoft` | **200**, 3.6 s — `numFound: 1` |
| 8 | `search.json?q=ia:(three ids)` | **200**, **546 ms** — all three works, one request |
| 9 | `search/inside.json?q=war` | **200** — 20 docs |
| 10 | `search/inside.json?q=war&page=2` | **200** — 20 docs, **2 of which repeat page 1** |
| 11 | `search/inside.json?q=war` (saved) | **200**, 8.5 s |
| 12 | `search/inside.json?q=love` (saved) | **200**, 4.0 s |
| 36 | `search/inside.json?q=war` (language census) | **200** — 9 English, 10 German, 1 undetermined |
| 37 | `search/inside.json?q=war AND meta_languageSorter:English` | **200** — **0 docs**; no language filter exists |
| 41 | `search.json?q=ia:(10 English ids)` | **200**, 2.7 s — 8 works; **2 ids cross to nothing** |
| 46 | `search/inside.json?q=war&page=2` (saved) | **200**, 5.9 s |
| 47 | `search.json?q=ia:(7 English ids from page 2)` | **200**, **407 ms** — 6 works |

### Part 2 — the Wikidata Query Service, the brief's query (3 requests)

The query #109 Phase 3c specified, VALUES-bound on sitelinks exactly as
`Corpus.WikidataFamous` is:

```sparql
?work wdt:P648 ?olid ; wdt:P31/wdt:P279* wd:Q7725634 ; wdt:P50 ?author
```

| # | Band | Result |
|---|---|---|
| 13 | `VALUES ?sitelinks { 60 }` | **502** after 53.1 s |
| 14 | `VALUES ?sitelinks { 60 … 99 }` | **504** after 84.3 s |
| 15 | `VALUES ?sitelinks { 30 31 32 }` | connection **closed** after 52.1 s |

**Three bands, three failures.** The brief's query does not answer. See
*What the documents got wrong*.

### Part 3 — finding a shape that does answer (3 requests)

| # | Shape | Result |
|---|---|---|
| 16 | the same band with **no class filter** | **200** in **3.9 s**, 5 items |
| 17 | the same band with direct `wdt:P31 wd:Q7725634` | **200** in 0.8 s, the same 5 |
| 18 | `?c wdt:P279* wd:Q7725634` on its own | **200** in 2.9 s — **5,597 classes** |

The `P31/P279*` path was the whole cost. 5,597 classes is also far too many to
put in a `VALUES` clause, so the class axis moves to the describe pass, where
the items are already named.

### Part 4 — measuring the sitelink floor (12 requests)

Bands of exact sitelink counts, `wdt:P648` + `wdt:P50`, no class filter.

| # | Band | Result | Items |
|---|---|---|---|
| 19 | 100–400 | **200**, 2.3 s | 42 |
| 20 | 60–99 | **200**, 3.3 s | 169 |
| 21 | 40–59 | **502**, 0.1 s | — |
| 22 | 30–39 | **200**, 12.2 s | 434 |
| 23 | 25–29 | **200**, 5.9 s | 407 |
| 24 | 20–24 | **200**, 11.8 s | 615 |
| 25 | 15–19 | **200**, 18.7 s | 1,059 |
| 26 | 12–14 | **no answer**, 78.8 s | — |
| 27 | 10–11 | **200**, 7.7 s | 916 |
| 28 | 8–9 | **no answer**, 72.9 s | — |
| 29 | 6–7 | **no answer**, 32.7 s | — |
| 30 | 5 | **no answer**, 5.2 s | — |

3,105 distinct items measured. Cumulative: **≥15 → 2,288**, ≥20 → 1,440,
≥25 → 917, ≥30 → 545, ≥100 → 37.

**The floor is 15, and it is set by reliability rather than by taste.** Below
15 the bands stop answering: 12–14, 8–9, 6–7 and 5 all failed, and a floor
inside a range the walk cannot read would be a corpus nobody could rebuild.

### Part 5 — the corpus build (35 requests)

One closure query, eight sitelink bands, twenty-six describe batches of 100
bound QIDs. **34 × 200, 1 × 502 retried and recovered, 0 unrecovered failures.**

### Part 6 — the empty-path probe (3 requests)

| # | Word | Docs |
|---|---|---|
| 71 | `fitfluencer` | **0** |
| 72 | `hydrostannane` | 7 |
| 73 | `cryoanesthesia` | 20 |

`fitfluencer` is the word the browser proof's negative-cache check uses.

### Part 7 — the browser proof's own live requests (5)

Recorded by `discovery_request_attempts`, which is the record of what was
actually spent: 2 for `/define/war`, 2 for `/define/love`, 1 for
`/define/fitfluencer`. Every later page load was answered from cache and spent
nothing.

**Running total: 78 of 300.**

---

## What the live provider does

Two stages, because the search index and the identity index are different
things:

1. `GET /search/inside.json?q=<word>&page=<n>` — 20 documents a page, with the
   snippets. It answers with **Internet Archive** identifiers, not OLIDs.
2. `GET /search.json?q=ia:(<id> OR <id> …)&fields=…` — **one** request for the
   whole window, crosswalking to `/works/OL…W`.

Then three gates, in order, before anything becomes an item:

| Gate | What it drops | Measured |
|---|---|---|
| **language** | a document whose `meta_languageSorter` is not the target's language | 10 of 20 on page 1 for *war* |
| **word boundary** | a snippet that does not use the term as a word, markers stripped | 0 of 40 for *war* and *love* |
| **crosswalk** | a candidate with no Open Library work | 2 of 10, then 1 of 7 |

### The language gate is the interesting one

`search/inside.json` is language-blind and **has no language parameter** —
request 37 measured `meta_languageSorter:English` returning zero documents, so
the filter is ours to apply or not at all. Half of the first page for *war* is
German prose: German *war* is the past tense of *sein*. It is the clearest case
in the kit of a search's own ranking proposing something that is not evidence.

**It is not a complete fix, and the fixture records why.** `jovana0000utta` and
`wolfskinder0000john` are filed by the Internet Archive as *English* and are
plainly German — `Er {{{war}}} es, der ihr nachgegangen {{{war}}}?`. They pass
the gate and reach the shelf. The gate is only as good as the source's own
language metadata, and this is the limit of it.

### The crosswalk drop is not a bug

`resorttowardatag0000sark` is Open Library's **first** result for *war* and
crosses to no work through `ia:`, even though `archive.org/metadata` names
`OL16946778W` for it (request 3). It is dropped. No OLID, no identity, no item
— which is the README's rule applied to the one identifier this provider
exists to publish. The alternative, a crosswalk through `archive.org/metadata`,
is one request per candidate at 4.2 s against one request per window at 0.5 s,
and was rejected on that.

### Pagination overlaps, and the cursor is an offset

Page 1 and page 2 of `search/inside.json?q=war` share **2 of 20** documents
(requests 9 and 10). The cursor is therefore an offset into the *candidate
stream* — `offset + consumed`, where a rejected candidate is still consumed —
and not a page number, so a `result_limit` smaller than the source's page
resumes inside the same page instead of skipping the rest of it. The pipeline
dedups on `external_id` on top of that.

---

## The corpus: `open-library-v1`

**946 rows, 413 distinct authors, checksum `e12ca37d…`.** Built from Wikidata,
keyed on the Open Library id Wikidata already publishes (`P648`).

| | |
|---|---|
| walk | `VALUES ?sitelinks {…}` + `wdt:P648` + `wdt:P50`, no class filter |
| describe | `VALUES ?item {…}` — label, `P31`, `P577`, each author's `P570` |
| class filter | `P31` within the 5,597-class subclass closure of `Q7725634`, applied locally |
| floor | sitelinks ≥ 15 |
| public domain | `P577` ≤ 1929 (**775 rows**), or no `P577` and every author died ≤ 1955 (**171 rows**) |
| dropped | 1,511 — not a literary work, or not provably public domain |
| smoke test | `Q161531` (*War and Peace*) is present |
| covers | **none recorded** — see below |
| image bytes | **0** |

### The public-domain rule was not given, so it is stated

The brief asked for public-domain works and named no test. A work is kept when
its earliest `P577` publication year is **1929 or earlier** — the United States
bright line, the same one Phase 3b used for Chronicling America — **or** it has
no `P577` at all and **every** named author has a `P570` death year of **1955
or earlier** (life + 70, as of 2026).

A work with neither a publication date nor a dated author is **dropped**. These
rows are shown to readers as public domain, and a guess is the one claim a
corpus exists to avoid. The rule and both counts are in the committed file's
`selection.public_domain`.

### No cover URLs in the manifest

`P648` yields **work** OLIDs (`OL…W`). Open Library's cover API serves edition
ids and cover ids, not work ids, so a cover URL on these rows would be a URL
that 404s. The live provider records one where `search.json` returns a `cover_i`
to build it from. Neither fetches bytes. The `:text` content type has no image
slot at all, so neither is rendered today.

### Seeding

Idempotent, measured on `devils_dictionary_v2`:

| Run | rows | newly created | matched | invalid | conflicting |
|---|---|---|---|---|---|
| 1 | 946 | 880 | 66 | 0 | 0 |
| 2 | 946 | **0** | **946** | 0 | 0 |

Afterwards: 946 `olid` identifiers, 946 distinct, 946 rows with
`work_details.work_kind = 'book'`.

The 66 matched on the first run are works the registry already held under their
Wikidata QID, which the seeder records beside the OLID. That is the crosswalk
doing its job, not a collision.

---

---

## The browser proof

`mix compile` to completion, then one dev server on `devils_dictionary_v2`.
Screenshots driven over CDP with `Emulation.setDeviceMetricsOverride`, because
headless Chrome's `--window-size` sets the window and not the layout viewport.

| Page | Width | `scrollWidth` | Texts shelf | File |
|---|---|---|---|---|
| `/define/war` | 1280 | 1280 | 13 | `issue-109-phase3c-war-1280-2026-09-18.jpg` |
| `/define/war` | 375 | **375** | 13 | `issue-109-phase3c-war-375-2026-09-18.jpg` |
| `/define/love` | 1280 | 1280 | 21 | `issue-109-phase3c-love-1280-2026-09-18.jpg` |
| `/define/love` | 375 | **375** | 21 | `issue-109-phase3c-love-375-2026-09-18.jpg` |
| `/define/war`, rail scrolled to the books/poems boundary | 1280 | 1280 | 13 | `issue-109-phase3c-war-shelf-books-and-poems-1280-2026-09-18.jpg` |

No horizontal page scroll at 375 on either page.

**Books beside poems on one shelf.** The Texts shelf's byline reads
*Open Library · attested books · PoetryDB · attested lines*, and the rail runs
ten Open Library books into three PoetryDB poems on `/define/war` — *War of
Attrition* (2015) next to Alan Seeger's *Ode in Memory of the American
Volunteers Fallen for France*. `/define/love` carries 21: eleven books and ten
poems. The fifth screenshot is that boundary.

The reason renders as `<Title>: Uses “war”.` in *About these results* — the
title is named beside the reason and the year is on the card. Never *about*.

### Declining, and the nearest true thing

A text provider matching by attestation covers every word, so its `covers?/1`
is the default `true` and there is no page it declines. The guide's §6 says to
verify the nearest true thing instead, and that is what was done, on
`fitfluencer` — a word Open Library's full-text search has no document for:

| Check | Result |
|---|---|
| shelf | empty — *No matching text for this term yet* |
| run | `succeeded`, `completion_reason: no_results`, 0 results |
| cost | **1 request** (the candidate search; the crosswalk is never reached) |
| reload | **0 further requests** — the negative cache answered |

### Every section, both pages

`/define/love` renders Johnson (noun and verb), Bierce, Open English WordNet
(noun and verb), Wiktionary (noun, verb and name), Wikipedia, the Artworks
shelf (4), the Texts shelf (21), Related words for verb and name, Browse,
Sources and Operations. `/define/war` adds the Images shelf (Wikimedia Commons)
and Related words for noun, verb and prefix, and opens on the bare lemma
`war · noun` — Phase 3b's ranking fix, still holding.

---

## What the documents got wrong

### 1. The query #109 gave for the corpus does not answer

`?work wdt:P648 ?olid ; wdt:P31/wdt:P279* wd:Q7725634 ; wdt:P50 ?author`,
VALUES-bound on sitelinks, answered **502**, **504** and a **closed
connection** on three separate bands (requests 13–15). The `P31/P279*` path
walks a 5,597-class closure per candidate.

The fix is the guide's own lesson applied one axis over: bind what you can,
and move what you cannot to the describe pass over named items, where
`Corpus.WikidataFamous`'s moduledoc already says the expensive parts get cheap.
The walk drops the class filter and answers in 3.9 s; `P31` is read in the
describe pass and filtered locally. **`docs/discovery/adding-a-provider.md` has
no worked example of a corpus walk**, only of a provider, which is why this cost
a phase's first hour to discover.

### 2. `MatchReason` cannot express a text locator that is not a line

`MatchReason.attestations/1` builds an attestation's locator as
`"line " <> number`, hardcoded. A book's attestation has no line to cite, and
`search/inside.json` returns **one** `page_num` for five snippets — measured —
so there is no per-snippet page either.

So #109's specified reason, *uses “war” in \<title\> (\<year\>)*, **cannot be
produced**. The options were to put a page number in a field the renderer
prints as `line N` — the provider lying about the medium to satisfy a renderer
— or to leave the locator empty. This phase left it empty: the shelf reads
*Uses “war”* with the snippet as the reason's note, beside the card's own title
and year.

The fix is one clause in a shared file — `attestations/1` reading an optional
`"locator"` from the line map and falling back to `"line " <> number` — and
this phase's permitted shared edits were the corpus registrations only, so it
was not made. **It is the second attestation provider that found this**, which
is exactly what #109 said a second one was for.

### 3. The generator's printout was sufficient, with one gap

`mix dd.provider.new open-library --archetype both …` named both edits it could
not make and all five `@kinds` keys with a one-line gloss each. That was enough
to write the registration without opening `manifest.ex` first — the first time
a corpus has been registered from the printout alone.

The gap: the **terminal printout** never names where the manifest is written or
what the kind string has to match. Both are in the generated module's
moduledoc, which is where a reader ends up anyway — but step 4 of the printout
says "build the manifest from the probe's rows and commit it" without saying
where, and `default_path/0` in the generated file is the only answer.

### 4. Two smaller ones

- `config/test.exs` sets `result_limit: 3`, not the `12` in `config/config.exs`.
  Nothing says so, and a fixture's expected ids depend entirely on it. The
  guide's §4 says the stub "returns the external ids it will produce, per page"
  without mentioning that the page size is a test-config value.
- The generator's scaffolded `config` stanza points at
  `https://open-library.example/api`, a URL with a path. Open Library's two
  endpoints are `/search/inside.json` and `/search.json` off the host root, so
  the endpoint is the host and the trailing path had to go.

---

## What is left out

- **No per-snippet locator.** See finding 2. The reason names no line or page.
- **The language gate trusts the Internet Archive's metadata**, which is wrong
  for at least two documents on page 1 of *war*. A German novel filed as
  English reaches the shelf.
- **The floor is 15 because 12 and below do not answer**, not because 15 is the
  right number of books. 817 more works sit between 10 and 14 and are not here.
- **Editions are not modelled.** `P648` also publishes edition (`OL…M`) and
  author (`OL…A`) ids; only `OL…W` work ids are kept, and an edition-level id
  is dropped rather than resolved to its work.
- **No negative-cache measurement for a word Open Library has never seen.**
  Every English word tried has scanned books using it; the empty path is
  covered by the conformance fixture's `:empty` stub and by a nonsense word in
  the browser proof, not by a natural miss.
