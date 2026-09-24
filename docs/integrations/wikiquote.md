# Wikiquote

Built 2026-09-23 as #158 builds 4a and 4. Scaffolded by `mix dd.provider.new
wikiquote --archetype discovery --content-type quote --transport get
--pagination offset --name Wikiquote`. The research and the decision to use
Wikiquote at all are #158 (Finding 1 and the Recommendation).

## Posture

| | |
|---|---|
| Slug | `wikiquote` |
| Archetype | discovery, on the `:quote` shelf (added here: build 1, which was to open it, had not started) |
| Endpoints | `GET https://en.wikiquote.org/api/rest_v1/page/html/<title>` (Parsoid HTML); `wbgetentities` on `https://www.wikidata.org/w/api.php` for the concept's sitelink; `action=query&prop=pageprops&ppprop=wikibase_item&redirects=1` on `https://en.wikiquote.org/w/api.php` for the linked authors' items. **Never** `action=parse` wikitext and **never** `list=search` (#158 Finding 1) |
| Licence | CC BY-SA 4.0. Text may be stored with attribution; every card carries *Wikiquote, CC BY-SA 4.0*. Retention durable |
| Key required | none |
| Published rate limit | Wikimedia's API etiquette: identify with a User-Agent, go serially |
| Measured sustainable rate | 200 ms spacing held for 34 requests across both hosts on 2026-09-23 with no `429` and no rising latency (and 55 in #158's probe). Shipped at 200 ms, the Wikidata client's own pace |
| Budget | `source_policies["wikiquote"]`: 600 an hour |
| Body cap | 2 MB. *Love* measured **1,450,960** bytes and *War* 728,736 |
| Images | none; the `:quote` row has no image slot |

## Probe and ledger

Ceiling for build 4's live run: **100 requests**. Written as each batch
finished.

| # | requests | what was asked | what came back | running total |
|---|---|---|---|---|
| P1 | 1 | `page/html/Nepotism` with curl, to read the Parsoid shape | 200, 21 kB; revision in `content-revision-id` and in `<html about=…/revision/N>`; **no Wikidata item in the HTML** | **1** |
| P2 | 7 | `mix dd.fixtures.capture --source wikiquote` (build 4a): Grief, Nepotism, Bank, Banking, Situationship, Voltaire, Kurt Vonnegut | 200 × 5; **Bank 307** with `Location: /w/rest.php/v1/page/Banking/html?redirect=no` (the core REST endpoint, not `rest_v1`); **Situationship 404** with a JSON body | **8** |
| L1 | 1 | `wbgetentities sites=enwiki` for the eleven probe words' Wikipedia articles, to get their concepts' QIDs | 200 | **9** |
| L2 | 32 | `Wikiquote.retrieve/4` itself, through a counting request function: *war* and *power* from the dev registry's own `refers_to`, and the other ten from L1's QIDs | 32 × 200 — see the table below | **41** |
| S1 | 1 | `page/html/War` into scratch, for the static render the screenshots were taken from (not committed) | 200, 729 kB | **42** |
| L3 | 30 | `retrieve/4` again after CodeRabbit's review moved the author stage from Wikidata's `wbgetentities sites=enwikiquote&titles=` to Wikiquote's own `action=query&prop=pageprops&ppprop=wikibase_item&redirects=1`: the ten words with a page | 30 × 200. Following redirects **recovered four credits** (Grief 11 → 12, Love 11 → 12, Power 2 → 3, Justice 9 → 10); War and Family each report one linked page with no item as `author_unresolved` | **72** |

Separately: one Commons thumbnail (`File:Wikiquote-logo.svg`, 250 px, 15 kB)
for the mark; see `docs/discovery/source-marks.md`.

### The live run, per word

| Word | QID | Page | Kept (page 1) | Register | Eras | Credited by sitelink | Requests |
|---|---|---|---|---|---|---|---|
| war | Q198 (dev registry) | War | 12, more behind | 0 | 👑 4 · 📚 4 · 📱 4 | 10 / 12 (1 unresolved) | 3 |
| power | Q911554 (dev registry: *business magnate*) | Business magnate | 3 | 0 | 👑 1 · 📚 1 · 📱 1 | 3 / 3 | 3 |
| nepotism | Q161165 (by enwiki) | Nepotism | 3 | 0 | 👑 1 · 📱 2 | 1 / 3 (Bierce) | 3 |
| grief | Q1026040 | Grief | 12, more | 0 | 👑 5 · 📚 1 · 📱 3 · undated 3 | 12 / 12 | 3 |
| love | Q316 | Love | 12, more | 0 | 👑 4 · 📚 2 · 📱 2 · undated 4 | 12 / 12 | 3 |
| family | Q8436 | Family | 12, more | 0 | 👑 3 · 📚 3 · 📱 4 · undated 2 | 10 / 12 (1 unresolved) | 3 |
| solitude | Q6010868 | Solitude | 12, more | 0 | 👑 7 · 📚 2 · 📱 2 · undated 1 | 9 / 12 | 3 |
| justice | Q13189320 | Justice | 12, more | 0 | 👑 4 · 📚 2 · 📱 1 · undated 5 | 10 / 12 | 3 |
| narcissism | Q186529 | Narcissism | 12, more | 0 | 📚 3 · 📱 8 · undated 1 | 6 / 12 | 3 |
| pop art | Q134147 | Pop art | 12, more | 0 | 📚 12 | 12 / 12 | 3 |
| bank | Q22687 | — | 0 | — | — | — | **1** |
| situationship | Q113952217 | — | 0 | — | — | — | **1** |

Ten of the twelve words have **no** `refers_to` QID in the development
registry, so in the real pipeline they decline at coverage and spend nothing;
the rows marked *by enwiki* are the probe standing in for what those pages
would do once their senses refer to their concepts. Credits are L3's, after
the review's change to the author stage.

## What identity a result carries

- Source identifier: the page's `enwikiquote` sitelink on the concept's QID,
  and per line the page + section chain + position, hashed
  (`wikiquote_item`), beside the line's `quotation_fingerprint` (ADR 0003)
- Encyclopedia identifier: the QID a sense `refers_to`
- Crosswalk: Wikidata's own sitelink, read by `wbgetentities`. Authors: the
  page a citation links to first, resolved to its Wikidata item by
  Wikiquote's page properties (`wikibase_item`, the other end of the same
  sitelink), redirects followed — never by name. A linked page with no item
  is reported on the item as `author_unresolved`. `:candidate` on a theme
  page; `:verified` for an author page's own cited work

## Measured facts

- **Bank's concept has no Wikiquote page.** Q22687 (bank, the financial
  institution) carries no `enwikiquote` sitelink; *Bank* on Wikiquote is a
  redirect to *Banking*, which Wikidata links to a different item. So the
  redirect path is real (fixture) but a sitelink rarely lands on a redirect:
  sitelinks name canonical pages.
- **A redirect goes to a different endpoint.** `rest_v1/page/html/Bank`
  answers 307 to `/w/rest.php/v1/page/Banking/html?redirect=no`. One redirect
  is followed; the HTML's `dc:isVersionOf` names the page it is a version of,
  which is where the title comes from.
- **The citation year is not always the work's year.** Aeschylus's
  *Agamemnon* is cited with its 1956 translation, so the line bands 📚, not 👑.
  The band is the citation's earliest year, as decided (open question 4);
  build 5's primary-text check is where a work's own date could correct it.
- **Voltaire's 116 is his *Quotes* section.** The page also holds 62 lines
  *about* him (and one about Voltaireans); #158's count left those out.
- **Kurt Vonnegut's Quotes is 334 now**, 333 on 2026-09-22.
- **None of the probe words' theme pages has a register section today.**
  The register is proved on the author pages (Voltaire 15 misattributed + 5
  disputed; Vonnegut 3) and on *Banking* (3 disputed).
- A theme page's line credits someone only when its citation **links** their
  page: 6 of Narcissism's 12, 12 of Pop art's.

## Conformance

    mix test test/devils_dictionary/discovery/conformance/wikiquote_conformance_test.exs
    mix test test/devils_dictionary/discovery/providers/wikiquote_parser_test.exs
    mix test test/devils_dictionary/discovery/providers/wikiquote_test.exs

## Corpus

Build 6 of #158, issue #174: the public-domain Wikiquote corpus,
`wikiquote-pd-v1`. The spike, run 2026-09-24, decides how the corpus reads its
pages, and it decides by counting them.

### What the selection needs

The selection, per #174's design and decision 1 (sense-level only, no lexeme
fallback), is two sets of pages:

- **Theme pages.** For every concept a sense `refers_to`, the page its
  `enwikiquote` sitelink names.
- **Author pages.** For every person the registry holds with a QID, their own
  page.

Both sets are counted locally, without the API. `enwikiquote-latest-page_props.sql.gz`
maps every page to its `wikibase_item`, the other end of the sitelink, and
`enwikiquote-latest-page.sql.gz` gives the titles. The two files are the
2026-09-01 dump. They were intersected with the development registry's
verified `wikidata` identifiers.

| | count |
|---|---|
| Wikiquote main-namespace pages, not redirects | 71,281 |
| of which carry a Wikidata item | 67,654 |
| distinct QIDs an active `refers_to` on a sense points at | 6,972 |
| **theme pages**: those QIDs with a Wikiquote page | **876** (583 concepts, 135 persons, 127 taxa, 19 places, 10 works, 2 organisations) |
| registry persons with a verified QID | 6,674 |
| **author pages**: those persons with a Wikiquote page | **558** |
| union of the two | 1,299 |

A line enters the corpus only when build 5's checks find it in a Gutenberg
text that Wikidata says its credited author wrote (`P50` + `P2034`). A person
with no such text dated before 1931 cannot contribute a *Verified* line, so an
author page is worth reading only when its subject has one. One SPARQL query
lists every item that has both `P2034` and `P50` (C4).

| | count |
|---|---|
| Wikidata items with a Gutenberg ebook id (`P2034`), all of them | **4,003** (C5) |
| of which have an author (`P50`) on the same item | 3,159 |
| of which the items with no `P50` would reach one through `P629` | 49 |
| authors with such a work whose `P577` is before 1931 | **1,107** (2,226 works) |
| **author pages** whose subject is one of them | **24** |
| of which are already theme pages | 21 |
| **pages the selection needs** | **879** |

A theme page cannot be pre-filtered the same way. Its lines credit whoever
their citations link, and nobody knows who that is until the page has been
read.

### Ledger

Ceiling: **100 live requests**. Every request carried an identifying
User-Agent and was sent at least 300 ms after the one before.

| # | requests | what was asked | what came back | running total |
|---|---|---|---|---|
| C1 | 1 | `dumps.wikimedia.org/enwikiquote/latest/enwikiquote-latest-page_props.sql.gz` | 200, 2,376,204 bytes, 1.3 s | **1** |
| C2 | 1 | `…/enwikiquote-latest-page.sql.gz` | 200, 8,050,961 bytes, 2.2 s | **2** |
| C3 | 1 | the `latest/` index, for the dump's date and the articles file's size | 200: 2026-09-01; `pages-articles.xml.bz2` 216,733,696 bytes | **3** |
| C4 | 1 | SPARQL: every `?work` with `P2034` and `P50`, plus `P577` where present | 200, 3,522 rows, 12.2 s | **4** |
| C5 | 1 | SPARQL: how many items carry `P2034`, and how many would reach an author only through `P629` | 200: 4,003 and 49, 12.1 s | **5** |
| C6 | 15 | Parsoid `page/html/<title>` for 12 theme pages (*War* plus 11 drawn with seed 174) and 3 author pages (Bierce, Twain, Wilde), parsed by `Wikiquote.Parser` | 15 × 200, 1.87 MB, 412 ms mean. Cited lines: War 670, Mercury 56, Menander 50, LSD 28, Hong Kong 12, Thursday 12, Libya 11, Alabama 9, Prague 8, Bread 8, Denver 3, *Gospel of John* 1; Bierce 179, Twain 228, Wilde 304 | **20** |
| C7 | 9 | `action=query&prop=pageprops&ppprop=wikibase_item&redirects=1` on the theme pages' first citation links, 50 at a time, as the provider asks | 9 × 200: 431 titles, 403 resolved to an item | **29** |
| C8 | 30 | Gutenberg `cache/epub/<n>/pg<n>.txt` for the first 30 pre-1931 works of the authors credited in C6 and C7 | 30 × 200, 13.1 MB, 816 ms mean | **59** |

**59 of 100.**

### What the sample found

- **833 candidate lines across 59 authors.** A candidate is a cited line
  whose credited author has a Gutenberg work dated before 1931. The credit
  came from the author page's subject or from the theme page's first
  citation link, resolved by page properties.
- **90 are Verified by `Checks.match_texts/2`**, and that is from only the
  thirty texts C8 fetched. Three of the 90 are from *War*: Lincoln, "The
  ballot is stronger than the bullet", in Gutenberg #61966, and two passages
  of Scott's *Marmion* (1808), in #5077. The other 87 are Wilde, found in
  *The Soul of Man under Socialism*, *An Ideal Husband*, *De Profundis*, *The
  Ballad of Reading Gaol* and four more.
- **The locator is sometimes `line ?`.** When a passage wraps across more
  than three of the text's lines, `line_number/2` finds the passage but not
  the line it starts on. The manifest records the locator as the check
  returns it.

### The decision: route (a), Parsoid and build 4a's parser

- **The number is small.** 879 pages at the provider's pace is about ten
  minutes, once, per corpus version. The page-properties calls on the theme
  pages' citation links cost about one request per fifty links on top of that.
- **One parser means one fingerprint.** A wikitext parser would be a second
  reading of the same lines. Wikitext has templates (`{{w|…}}`), `''italic''`
  and `<ref>`, and a second parser would draw line boundaries its own way. A
  corpus line and a live line that disagree by one character have two
  fingerprints (ADR 0003), so they would not fold into one subject, and that
  folding is #174's acceptance box. Route (a) runs the **same** `Parser.parse/1`
  that the live provider and the verifier's author-page check run.
- **Reproducible anyway.** Parsoid serves a pinned revision at
  `page/html/<title>/<revision>`. The manifest's `selection` block records
  each page's revision id, so a re-run reads the same HTML the first run read.
  The dump buys nothing here that the revision ids do not.
- **The dump still has a use**, and it is counting. The two small SQL files
  (10 MB) told the spike which pages to read. The 217 MB articles file is not
  needed.

The spend that matters for the build is not Wikiquote at all. It is
**Gutenberg**: one text per pre-1931 work of every author a kept line credits,
and at most 2,226 works exist. The build fetches each text once, paces it at
one second, and records every text's ebook number in the manifest.
