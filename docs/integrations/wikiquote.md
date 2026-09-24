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
| Endpoints | `GET https://en.wikiquote.org/api/rest_v1/page/html/<title>` (Parsoid HTML); `wbgetentities` on `https://www.wikidata.org/w/api.php` for the concept's sitelink and, in the same request, its claims for the concept hop (one more `wbgetentities` per hop step, at most two; #172 build A); `action=query&prop=pageprops&ppprop=wikibase_item&redirects=1` on `https://en.wikiquote.org/w/api.php` for the linked authors' items; `https://query.wikidata.org/sparql` for which of those items are people (`P31` = `Q5`, one `VALUES` query per page). **Never** `action=parse` wikitext and **never** `list=search` (#158 Finding 1) |
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
  first page a citation links to **whose item is a person**. Each linked page
  is resolved to its Wikidata item by Wikiquote's page properties
  (`wikibase_item`, the other end of the same sitelink, redirects followed),
  and one `VALUES … wdt:P31 wd:Q5` query to the query service says which of
  those items are humans. Never by name. A citation that links a work or a
  theme page first (*Impropriety*, then *Horace*, on Grief) is credited to
  the person. One whose linked items are none of them people credits nobody
  and opens no `unresolved_creator` case (the audit of #169, residual 1). A
  first link with no item at all is still reported on the item as
  `author_unresolved`. If the query service cannot answer, the first link is
  credited, as before. `:candidate` on a theme page; `:verified` for an author
  page's own cited work
- **No page property says "person".** Wikiquote's `pageprops` on an author
  page are `wikibase_item`, `page_image_free` and sometimes `defaultsort`
  ("Addison, Joseph", which is a sort key made from the name and is missing
  on *Voltaire*). Only `P31` can say it, hence the one query (1 request,
  2026-09-24)

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

## Concept hop

Built 2026-09-24 as #172 build A. A sense's item with no `enwikiquote`
sitelink still reaches the page of a concept Wikidata says it relates to:
*coward* (Q104605901, "cowardly or fearful person") `P1552` *has
characteristic* *cowardice* (Q1401607) → *Cowardice*. The walk is
`DevilsDictionary.Discovery.ConceptHop`, shared by the provider and the
corpus build.

| | |
|---|---|
| Properties, in order | `P1552` has characteristic · `P279` subclass of · `P1269` facet of · `P31` instance of (`ConceptHop.@properties`, each with its one phrase) |
| Steps | at most two; the first step that reaches any page ends a provider's walk; a third step is never fetched |
| From | an item the registry holds as a `concept` or an `event`, and never one whose own `P31` is a person or a work |
| Never onto or through | an item whose `P31` is human, fictional human, character, or one of 14 creative-work classes (`@refused`, labels confirmed live in H1) |
| `P31` | only from an instance (no `P279` of its own), only onto a class (has a `P279`), and only as the last step — the two guards H3 and H4 added after H2 |
| Cost | the sitelinks request carries `props=sitelinks\|claims` (filtered client-side by `WikidataClient.hop_nodes/3`), so a direct sitelink costs nothing extra; each step one more `wbgetentities`, on its own stage (`hop:1`, `hop:2`) so each step has its own retries. *coward* costs 5 requests on the Wikiquote budget (sitelinks, hop:1, page, authors, humans) |
| Record | the recipe freezes the rule (`parameters["hop"]`) and `mapping_identity/1` digests it; each result's `match_details["sitelinks"][…]` carries `"from"`, `"via"` and `"reached"`; the corpus row carries `concept_qids_via` |
| Reason | *From Wikiquote's page “Cowardice”, the concept a sense of “coward” has as its characteristic (Q1401607).* |

### Ledger

Ceiling: **60 live requests**. Every request carried the project's
User-Agent, at least 300 ms after the one before.

| # | requests | what was asked | what came back | running total |
|---|---|---|---|---|
| H1 | 1 | `wbgetentities props=labels` for the 17 refused classes | all 17 labels as intended (human … comic) | **1** |
| H2 | 4 | the hop alone on the 13 probe words (#158's twelve + *coward*), senses from the dev registry: `sitelinks\|claims` for the 3 words with a sense link, one hop step | table below | **5** |
| H3 | 7 | the hop on a fixed sample of 50 of the registry's 2,165 hop origins (lowest `md5(qid)`), before the `P31` guards | direct 12 · hop 21 · neither 17 — with *luthier* → *profession* → **Wage**, *witch doctor* → *occupation* → **Labor**, *aunt* → **Brotherhood** | **12** |
| H4 | 5 | the same sample with `P31` read only off an instance | direct 12 · hop 18 · neither 20; *witch doctor* → **Labor** still (it has no `P279`) | **17** |
| H5 | 5 | the same sample with `P31` also a last step only (as built) | direct 12 · **hop 17** · neither 21 | **22** |
| H6 | 1 | `mix dd.fixtures.capture --source wikiquote --page Cowardice` | 200, 55,883 → 33,701 bytes, 67 quotations, revision 3927892 | **23** |
| H7 | ≤10 | two screenshot-server attempts with Oban `:inline`: the job ran inside `Discovery.request`'s own transaction and timed out; both rolled back, taking their budget rows with them, so this is an upper bound | no run persisted | **≤33** |
| H8 | 6 | `/define/coward`'s mapping run once on the dev database, in-process with no Oban job (5 Wikiquote stages + 1 `wikidata:entity` for creator identity) | succeeded; 11 results from *Cowardice*, each with `via` `P1552` | **≤39** |

**≤39 of 60.**

### The probe words, by the hop alone

| Word | Sense link (dev registry) | Before | After build A |
|---|---|---|---|
| **coward** | Q104605901 coward | no page | **Cowardice** by `P1552` → Q1401607 |
| war | Q198 | War (direct) | unchanged |
| power | Q911554 *business magnate* | Business magnate (direct) | unchanged |
| nepotism, grief, love, family, solitude, justice, bank, pop art, situationship, narcissism | none | no shelf | no shelf — nothing to hop from; build B's |

So the hop alone gains **one** of the thirteen. On the 50-concept sample it
reaches a page for **17** that had none (34 %), against 12 with a page of
their own. What it reached, as built:

| From | Page | Path |
|---|---|---|
| plough | Tool | `P279` |
| kitten | Cats | `P279` |
| gelding | Horses | `P279` |
| saltwater fish | Fish | `P279` |
| Fighter aircraft | Airplane | `P279` → `P279` |
| Suffolk Punch | Horses | `P279` → `P279` |
| brit milah | Circumcision | `P279` → `P279` |
| Romani language | Indo-Aryan languages | `P279` → `P279` |
| roller skating | Sports | `P279` → `P279` |
| fingerprint | Results | `P279` → `P279` |
| loan shark | Abuse | `P1552` → `P279` |
| Underground Railroad | Confidentiality | `P1552` |
| Yellowknife | Cities | `P31` |
| Connecticut River | Rivers | `P31` |
| Cerro Bonete | Mountain | `P31` |
| Danish Realm | Countries | `P31` |
| West Coast of the United States | Coast | `P31` |

Two read as a stretch (*fingerprint* → *Results*, *Underground Railroad* →
*Confidentiality*), and both are what Wikidata states. The reason on every
card prints the path, so a reader can see how it got there.

**The registry's `concept` kind is loose.** The sample's direct pages
include *Cosimo de' Medici*, *Scotland* and *Moscow*, all held as `concept`.
The guards on `P31` refuse a person whatever the registry calls it. A place
held as a concept can still hop by `P31` to its class (*Yellowknife* →
*Cities*).

## Word-level tier

#172 build B. A page whose senses refer to nothing still reaches a concept
when the ladder (`Absorb.Linker`) wrote a **corroborated** word-level
candidate for it: a `lexeme_entity_candidate` at confidence ≥ 0.85. The shelf
is then labelled *For the word "…", not a particular sense*. The spike below
was measured before any code, on the dev database (`devils_dictionary_v2`),
2026-09-24.

### What the ladder holds

| | count |
|---|---|
| `lexeme_entity_candidate` revisions (the issue's 76,195) | 76,195, of which **59,770 current** (59,769 active) |
| current, active, confidence ≥ 0.85, with a verified Wikidata identifier | **13,884** on 13,884 lexemes, 13,548 pages |
| … by corroboration | `gloss_overlap` 6,613 (0.85) · `taxon_name` 6,376 (0.90) · `qid_agreement` 895 (0.90) |
| … on lexemes in a ladder scope | all of them: the ladder runs per scope (animals 25,385 · emotions 809 · culture 5 lexemes) |

**The ladder does not record which sense a gloss matched.**
`corroborate_gloss/2` asks `EXISTS (a sense of the lexeme whose gloss shares
two content words with the article)` and writes
`{"corroboration": "gloss_overlap"}` and nothing else. Recomputed per sense
with the same rule:

| the 6,613 gloss corroborations | |
|---|---|
| exactly one sense matches | 4,781 |
| several match, one shares the most words | 1,479 |
| several tie for the most | 353 (mostly one meaning in two dictionaries: *zooplankton*, *snakebird*, *world-weariness*) |
| **promotable**: a unique best sense, the entity not a person (10), the sense without an active `refers_to` of its own (21) | **6,230** senses on **6,180** pages |

`taxon_name` and `qid_agreement` are not gloss matches, so they are never
promoted: a taxon name agrees with the *word*, and an agreement is already a
sense-backed link to the same entity.

**The dev database lost its WordNet links today.** At 18:41 a WordNet
re-materialization's reconcile withdrew all 13,960 `wordnet_wikidata` and
10,236 `wordnet_ili` links as *no longer emitted by its source* (the ladder
registers the WordNet record as their provenance). Pages with an active
sense-backed link: **14,676** as the ladder wrote them, **1,810** now. Both
columns are measured below; the fix is a separate task, not this build.

### Ledger

Ceiling: **60 live requests**, `wbgetentities props=sitelinks|claims
sitefilter=enwikiquote`, fifty to a request, the project's User-Agent, at
least 350 ms apart, memoized so no QID was asked twice.

| # | requests | what was asked | what came back | running total |
|---|---|---|---|---|
| W1 | 2 | the 53 QIDs of 113 words (13 probe words, 50 random common nouns, 50 random nouns in the animals and emotions scopes), both tiers | sitelinks and hop claims for all 53 | **2** |
| W2 | 21 | `ConceptHop.reach/4` steps, one per word that hopped, as the provider walks them | table below | **23** |

**23 of 60.**

After the build, on the dev database, each run in-process with this branch's
code (no Oban job ever committed, so the main checkout's node on 4007 could
not claim one):

| # | requests | what was run | what came back | running total |
|---|---|---|---|---|
| W3 | 8 | Wikiquote for *grief* and *love*, word-level recipes (Q1026040, Q316) | 12 cited lines each, every one `"level": "word"` | **31** |
| W4 | 8 | the same after one promotion run: new recipes, sense-level | the same pages, 12 lines each, none word-level | **39** |
| W5 | 4 | Wikiquote for *prey* (word-level, Q170430 → *Predation*) for the screenshots | 12 lines | **43** |

(*prey*'s Commons run, 2 requests, 12 word-level depictions, and its Met run,
1 request, nothing, are on those providers' budgets.)

### After the build, and after one promotion run

The thirteen probe words, Wikiquote run for each page it covers:

| | Quotes shelf | of which word-level |
|---|---|---|
| after build B | 4 (*war*, *coward*, *grief*, *love*) | 2 (*grief*, *love*) |
| after one promotion run | 4 | 0 — *grief* and *love* each promoted to a Wiktionary sense (5 and 6 shared words) |

*power* has no shelf only because its WordNet link was withdrawn today (see
above); the other eight are in no ladder scope or, like *nepotism* and *bank*,
in one with no candidates.

The promotion run (`Linker.corroborate/1` per scope, app not started, run rows
196–198): **6,003** senses promoted in animals, **227** in emotions, **0** in
culture — the 6,230 the spike predicted. A second run wrote no revision.

| English lexemes with a sense-backed Wikidata link | before | after |
|---|---|---|
| lexemes | 1,849 | **8,053** |
| pages (lemmas) | 1,810 | **7,950** |
| still read at the word level (in scope, ≥ 0.85, no sense link) | 13,117 + 281 | 7,137 + 57 |

With the ladder's withdrawn WordNet links restored the before figure would be
the issue's 15,010; promotion's 6,230 would sit on top of it, less whatever
overlaps.

### Who gains a page

*Base* is a direct sitelink from a sense's item; *A* adds the hop (merged);
*B* adds a corroborated candidate's direct sitelink when the page has no
sense link; *A + B* is what ships. Sense links as the ladder wrote them; in
brackets, today's dev database.

| sample | n | base | A | B | A + B | of which word-level |
|---|---|---|---|---|---|---|
| probe words | 13 | 2 (1) | 3 (2) | 4 (3) | **5 (4)** | 2 |
| random common nouns (a WordNet and a Wiktionary noun, `^[a-z]{3,}$`, lowest `md5`) | 50 | 0 (0) | 1 (0) | 0 (0) | **1 (0)** | 0 |
| random nouns inside the animals and emotions scopes, same rule | 50 | 5 (4) | 8 (5) | 8 (8) | **16 (15)** | 8 |

The probe words:

| word | sense link | candidate ≥ 0.85 | page |
|---|---|---|---|
| war | Q198 (`wiktionary_qid`) | — | War, direct |
| power | Q911554 (`wordnet_wikidata`, withdrawn today) | — | Business magnate, direct; none today |
| coward | Q104605901 | — | Cowardice, by `P1552` (A) |
| **grief** | none | Q1026040, `gloss_overlap` | **Grief**, word-level (B) |
| **love** | none | Q316, `gloss_overlap` | **Love**, word-level (B) |
| nepotism, bank | none | none (in the culture scope, which has no candidates) | none |
| family, solitude, justice, pop art, situationship, narcissism | none | none (in no scope) | none |

What B reached in the scoped sample: *prey* → Predation, *masochism* →
Sadomasochism, *fondness* → Affection directly; *jennet* → Horses, *foxhound*
→ Dogs, *menhaden* → Fish (`P279`), *larva* → Animals and *malacologist* →
Zoology (`P279` → `P279`) by the hop from the candidate.

**B is bounded by the ladder's scopes.** Of fifty random common nouns, none
has a corroborated candidate, because the ladder has run on three scopes and
no others; inside those scopes B doubles what A reaches (8 → 16). Growing it is
a ladder run over another scope, not a change here.

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
- **Reproducible anyway, once the build pins it.** Parsoid serves a pinned
  revision at `page/html/<title>/<revision>`. The page reader as it stands
  (the live provider's and the verifier's) asks by title only, so on its own
  a re-run would read whatever the page is today. The build therefore keeps
  the revision id each first read returned (`<html about=…/revision/N>`) in
  the manifest's `selection` block, and a re-run asks for the title **and**
  that revision, which is the same HTML the first run read. The dump buys
  nothing here that the revision ids do not.
- **The dump still has a use**, and it is counting. The two small SQL files
  (10 MB) told the spike which pages to read. The 217 MB articles file is not
  needed.

The spend that matters for the build is not Wikiquote at all. It is
**Gutenberg**: one text per pre-1931 work of every author a kept line credits,
and at most 2,226 works exist. The build fetches each text once, paces it at
one second, and records every text's ebook number in the manifest.

### As built: `mix dd.quotes.corpus.build`

The build is `Quotations.Corpus.Build`, and the task that runs it is
`mix dd.quotes.corpus.build`. It writes
`priv/quotes/manifests/wikiquote-pd-v1.json`.

It reads the registry and writes nothing to the database. The task starts the
Repo and nothing else, so no Oban node runs. Every answer is cached under
`tmp/quotes-corpus-cache`.

**The first build, 2026-09-24.**

| stage | requests | |
|---|---|---|
| `sparql:works`, `sparql:originals` | 2 | every item with `P2034` + `P50` (and its `P577`); every one that is an edition or translation (`P629`) of a dated original. Apart, because together, with the label service, they timed out three times |
| `wikidata:sitelinks` | 147 | `enwikiquote` sitelinks for the 6,972 concepts and the persons with a pre-line work, fifty to a `wbgetentities` (a 400-QID `VALUES` query got a 504) |
| `parsoid` | 1,234 | 887 selected pages, then the own pages of the credited authors not already among them |
| `pageprops` | 112 | 5,580 linked pages resolved to their items |
| `wikidata:entities`, `wikidata:labels` | 7 + 28 | the 347 candidate authors' facts for the seeder, then the labels of their works |
| `gutenberg` | 1,405 | 1,392 texts, 13 × 404. One file came back as the gzip itself and several as Latin-1, hence `Checks.text_body/1` |
| **total** | **2,936** | |

| | |
|---|---|
| pages read | 887 |
| candidates: cited lines credited to an author with a pre-1931 Gutenberg work | 7,004, across 347 authors |
| **kept: Verified** | **1,053 lines**, 136 authors, 252 works |
| work year from the work's own `P577` / from its original's (`P629`) | 880 / 173 |
| filed under a concept a sense refers to | 1,052 (one line came from an author page only) |
| on `/define/war` (Q198) | 9: Scott's *Marmion* ×2 and *The Lady of the Lake*, Byron's *Childe Harold* ×2, Lincoln, Shaw's *Heartbreak House*, Wells's *War and the Future*, Campbell |
| most lines | Bierce 141, Wilde 89, Scott 75, Twain 70, Dickens 60, Hardy 53, Chekhov 48 |
| manifest | 3.5 MB; `set_checksum` `22d236e0cef4fff8555cb7e348b765923f037f9e3e5e1b4493dc6ad607336499` |

**Kept only when Verified.** A line's findings are these:

- the corpus's own claim (`wikiquote-pd-v1`, cited)
- a row in the page's own register with the line's fingerprint, which
  contradicts it
- `Checks.match_page/3` on the credited author's own page
- `Checks.match_texts/2` on that author's pre-1931 texts

`Badge.compute/2` has to say `verified`: two sources agree, one of them the
Gutenberg text, and nothing contradicts. The build does not call
`Verifier.verify_author/2`, because that writes verification runs, source
records and ledger rows. It runs the same pure checks.

**The line number.** `Checks.line_number/2` read three lines at a time and
answered `line ?` for a passage longer than that; the first sample had eight
lines of *O Captain!* at `line ?`. It now finds the passage in a per-line
normalised index, built once per text (`Checks.index_lines/1`). None of the
1,053 locators is `?`.

**Reproducible.** The `selection` block holds everything the network was
asked:

- the pages, each with its revision id
- the credits that led to a pre-line author
- each author's own page and revision
- the works with their ebook numbers and years
- each author's Wikidata facts

`mix dd.quotes.corpus.build` with the manifest in place re-runs from that
block alone. It reads each page as `page/html/<title>/<revision>` and asks
Wikidata nothing. Then it compares the rebuilt set with the committed one by
`set_checksum`. If they are the same, it writes nothing. If they differ, it
**refuses**, names what went and what came, and asks for a new version
(`--output …-v2.json`). `--reselect` makes a fresh selection from the
registry and today's pages, and is held to the same rule.
