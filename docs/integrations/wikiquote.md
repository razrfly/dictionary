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
