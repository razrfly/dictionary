# Wordhoard *(working title)*

> Every word, every source, one page. An aggregator of dictionaries, encyclopedias and the culture, layered by who did the defining: the dead, the institutions, the crowd.

Internal name: `devils_dictionary` (the Phoenix app, the repo). Product name is provisional; see [Naming](#naming).

This file is the **living record** of the project: what it is, what it is not, the decisions we've made, and what we plan to build next. Update it whenever a decision changes. The current implementation spec is [issue #69](https://github.com/razrfly/dictionary/issues/69).

---

## What it is

- **An aggregator, not an author.** We do not write definitions. We absorb every word from open sources, keep a short definition and a link back for every source that has one, and layer sources on top of each other so the reader sees who defined what, and how they disagree.
- **Complete first, deep later.** The lexicon (every English headword) exists from day one. Enrichment (senses, encyclopedia entries, links, media) is added scope by scope.
- **Provenance on every row.** Nothing appears on screen without the source it came from, a link out, and a way to see the raw record.
- **Living.** Sources are re-absorbed; new words, changed senses and new examples surface as feeds.
- **Interactive on top.** Once the backbone holds, people (and curator bots) attach examples, media and votes to words: *nepotism* gets its public figures, *situationship* gets its TikToks. The backbone stays read-only; the culture annotates it.
- **An app in the end.** Backend first, then an API, then a progressive web app and an iOS app. Think Instagram of an encyclopedia: a word of the day with its evidence, not a wall of text.

## What it is not

- Not Wikipedia. We store summaries and links, not articles. Full text is imported only from public-domain dictionaries (Webster 1913, Johnson 1755, Bierce, EB1911).
- Not a new dictionary. Our "definitions" are other people's, attributed.
- Not commercial. Only openly licensed and non-commercial-permitted sources; nothing unlicensed is bulk-stored or redistributed.

---

## The backbone

```
sources ──► source_records (raw, trimmed, hashed, linked) ──► materialize (pure, one transaction)
                                                                      │
              ┌───────────────────────────────────────────────────────┴──────────────────┐
              ▼                                                                          ▼
   LEXICON: lexemes (lang · lemma · pos) · senses · entries · lexical_relations   ENCYCLOPEDIA: concepts (QID) · concept_relations
              └──────────────────────── concept_links (method · confidence · status) ────┘
                                              ▲
                     scopes (animals …) · examples · media · votes · users · bots  (layers, later)
```

Three ideas carry everything:

1. **Words and things are different tables.** Dictionaries attach to words (lemma + part of speech). Encyclopedias attach to things (Wikidata QID). They meet only through typed, scored links.
2. **Tier is a property of the source.** 👑 *Aristocracy of the Dead* (Bierce, Johnson, Webster 1913, EB1911) · 📚 *The Institutions* (Wiktionary, WordNet, Wikidata, Wikipedia, Merriam-Webster) · 📱 *The Crowd* (Urban Dictionary, the Guardian's explainers, our own users). Add a source, and the UI already knows how to dress it.
3. **Raw first.** Every absorbed record is kept (trimmed to the fields we use) so every derived row can be rebuilt with the network off.

Patterns are borrowed from [Cinegraph](https://github.com/razrfly/cinegraph): raw JSONB per record, a behaviour per source, idempotent materialization, terminal-state predicates, an import dashboard, health checks.

---

## Status

**MVP-0, the walking skeleton, is in progress.** Spec: [#69](https://github.com/razrfly/dictionary/issues/69). Build tracker (reset procedure, sessions S0–S5, directory structure): [#70](https://github.com/razrfly/dictionary/issues/70). Five open sources (Open English WordNet, Wiktionary via Kaikki, Wikidata, Wikipedia, Bierce), one test scope (Animals), thirteen tables, six plain pages, and a scorecard that `mix dd.score` computes. MVP-0 is done when every scorecard row passes.

| Milestone | State |
|---|---|
| Direction decided, schema reviewed | ✅ 2026-09-05 |
| Repo reset in place: Phoenix 1.8.13 / LiveView 1.2.11 on Elixir 1.19 / OTP 28, directory structure scaffolded (#70 S0a) | ✅ 2026-09-05 |
| S0b thirteen-table schema, `Materializer`, WordNet full + Wiktionary index, Animals scope (A2 ✅ 120,564 synsets · A3 ✅ 1,534,818 lexemes · A4 ✅ 21,277 scope lexemes · R1 ✅ 100%) | ✅ 2026-09-05 |
| S1 Wiktionary scoped (19,251 records, 31,116 senses, 105,731 relations), `Resolver`, parity, `Health` (A9 ✅ 100% · M1 ✅ 0 gaps · M4 ✅ 67.7% on real records · R2 ✅ 86.4% · X3 ✅ · A5 ⚠️ 83.5%, see #69) | ✅ 2026-09-05 |
| S1b `content_hash` taken before `trim/1` (changed_at now moves only when the source moves), `form_of` flag on 533,218 index rows, headword-first lookup; Health rows unchanged (A5 raw 83.5 % / amended 92.2 %, A9 100 %, M1 0, M4 67.7 %, R2 86.4 %) | ✅ 2026-09-05 |
| S2 Wikidata + Wikipedia (44,194 concepts, 44,072 entries, 38,206 taxonomy edges, 65,679 links), Oban, the linking ladder (A6 ✅ 100% · A7 ✅ 100% · A10 ✅ 93.7% · L2 ✅ 1,165 surfaced · L3 ✅ 77.3% · L4 ✅ 100% · M1 ✅ 0 gaps · **L1 ⚠️ 57.7%**, ceiling 68.1%, see #69) | ✅ 2026-09-05 |
| S2 audit + completion pass: Wiktionary re-absorbed on the grown scope (+2,176 records, +3,367 senses), Wikidata +66, links re-run; L1 58.4 % raw / **88.5 % of reachable**, A6 union 97.4 %, A7 100 %, A10 93.6 %, L3 77.2 %, R2 86.4 %, M1 0 gaps across 242,359 records | ✅ 2026-09-05 |
| S3 Bierce (997 entries, 247 verse blocks), `Health.Coverage` + `Health.Score`, `mix dd.health`, `mix dd.score` (A1 ✅ 5/5 · A8 ✅ 997, 93.0% already in the index · M2 ✅ identical over 271,296 records · M3 ✅ · O1 ✅ · O3 ✅ · O4 ✅ — **24 / 24 graded rows pass**) | ✅ 2026-09-05 |
| S3 audited (grade A): scorecard reproduced, 24 / 24 graded rows pass on 261 tests; one parse nit (three alternate-headword bodies) noted for the next data touch. **U0, S4b and S5 unblocked.** | ✅ 2026-09-05 |
| U0 Oatmeal theme ported by hand into `DevilsDictionaryWeb.Kit` (17 components), daisyUI removed, `/kit` dev-only, no kit source in git | ✅ 2026-09-06 |
| S4b read layer (`Lexicon.browse/search`, `Encyclopedia.taxon_*`, `Health.records/source_detail`) and four developer surfaces: `/s/:slug`, `/sources/:slug`, `/admin/imports`, `/health` (U5 ✅ 5/5 · X2 ✅ p95 72 ms · U4 ✅ at 375 px — **26 / 26 graded rows pass**, 322 tests); Commons image URLs and nine Bierce bodies fixed | ✅ 2026-09-06 |
| S4 audited in Chrome (U0 **A**, S4b **B+**): every page, filter, link-out and theme verified; two click-level defects (has/missing chips dead, `/health` abandons its own mount) and A5 v2 → **S4c** in #70 | ✅ 2026-09-06 |
| S4c fixes from the audit: chips carry `phx-value-slug`; the scorecard is `assign_async` + a ten-minute Cachex cache with a *recompute* button (health page dead render 3 ms, websocket kept); Wikidata shown as *linked · 16,014* from `concept_links` with its dead chips gone; no more `page=false`; **A5 v2 93.0 %** excl. 4,004 scientific names at a 90 % bar — all verified in Chrome, 322 tests | ✅ 2026-09-06 |
| U1–U3 the word page and the hop, home/search, provenance, fake-data mode (#71) — the rows R3 X1 U1 U2 U3 U6 | ⬜ |
| S5 extensibility proof (Johnson 1755, a toy scope) | ⬜ |

---

## Roadmap (living; reorder freely)

Everything below is designed for in the MVP-0 schema and adds tables rather than changing them.

**Layers (more sources)**
- [ ] Johnson 1755 (LEME TEI-XML, CC BY 4.0) · Webster 1913 (GCIDE) · EB1911 (Britannica11 corpus)
- [ ] Wikidata lexemes dump (the P5137 word→thing bridge)
- [ ] Merriam-Webster (1k/day, non-commercial) · Urban Dictionary (on demand, attributed, never stored in bulk) · Datamuse
- [ ] Voltaire's *Philosophical Dictionary* · Diderot (link only) · the Guardian Gen Z terms (#63)
- [ ] More scopes: emotions, politics, food, internet slang. A scope is one task run.

**Community**
- [ ] Users (Clerk or `phx.gen.auth`), roles
- [ ] **Examples**: "X is an example of this word" where X is a thing (a person, a company), a URL (a news story) or text; submitted by a person or a bot; voted on
- [ ] Votes with cached scores; moderation queue
- [ ] Curator bots with personalities (#17)
- [ ] Quotes with provenance scoring (#65)

**Media**
- [ ] Evidence wall (#67): paste a link, unfurl it, attach it to a word
- [ ] Media providers as sources: YouTube, TikTok, Instagram, X, Giphy, Unsplash, Spotify/Genius, TMDb (via Cinegraph), news
- [ ] Images on every word and thing (Wikipedia thumbnails, Wikidata P18, Commons)

**Product**
- [ ] Feeds: new words, changed senses, top examples, word of the day
- [ ] Minimum word-hopping UI on the Oatmeal theme, theme boilerplate first, with a labelled fake-data mode (#71)
- [ ] Design pass on the word page (#66): the tier styling *is* the joke, on top of #71
- [ ] JSON API (then GraphQL) over the same contexts
- [ ] Progressive web app
- [ ] iOS app
- [ ] Concept pages, disambiguation pages, etymology trees

**Ops**
- [ ] Kamal deploy to the Argus NUC as a second database
- [ ] Daily re-absorb and drift checks (Cinegraph-style sweepers)

---

## Decision log

| Date | Decision | Where |
|---|---|---|
| 2026-09-05 | Absorption-first: absorb the open word graph, layer dictionaries on top. Supersedes the API-first plan in #68. | #69 |
| 2026-09-05 | Restart the code from `mix phx.new`, **in place** in this repo and directory; keep the repo and issues. The Rails app is already tagged `ruby-rails-archive`; the skeleton gets `phoenix-skeleton` before the wipe. | #69, #70 |
| 2026-09-05 | One app, one database; neutral core contexts `Absorb` / `Lexicon` / `Encyclopedia`. | #69 |
| 2026-09-05 | Full lexeme index from day one; enrichment scoped. Test scope: Animals. | #69 |
| 2026-09-05 | No sense alignment across sources; join only through concepts. Disagreement is content. | #69 |
| 2026-09-05 | Non-commercial. Open sources only in MVP-0. | #69 |
| 2026-09-05 | The word is the page (`/define/:slug`, all parts of speech, all sources). | #69 |
| 2026-09-05 | Tier is a column on `sources`, a theme not the core. | #69 |
| 2026-09-05 | Pinned snapshots; no daily sync yet. | #69 |
| 2026-09-05 | Links, not content: short gloss + URL for living sources; full text only for public-domain dictionaries; raw records trimmed. | #69 v3 |
| 2026-09-05 | Humans and bots are sources. Examples and media are edges from words to things/URLs with provenance and votes. | #69 v3 |
| 2026-09-05 | Backend first, then API, then PWA, then iOS. | this file |
| 2026-09-05 | MVP-0 is built in six to eight sessions (S0–S5), each ending with numbers posted on #70. | #70 |
| 2026-09-05 | Always generate and stay on the current Phoenix release; toolchain pinned per project in `.tool-versions`. Reset done with `phx_new` 1.8.13. | #70 |
| 2026-09-05 | S0 audited. Animals scope measured at 21,277 lexemes (estimate was 8k–12k): kept whole, enriched in reason order; the O2 time budget is split into dump absorbs (≤ 2 h) and on-demand fetches (reported). WordNet is the plus edition; `wordnet_wikidata` joins the linking ladder. | #69 v6, #70 |
| 2026-09-05 | S1: **A5 cannot pass as specified** — Wiktionary attests 83.5% of the Animals scope, and the 3,504 misses are 1,995 Linnaean binomials plus 1,299 other multiword names that Wiktionary files under Translingual, not English. Reported rather than engineered around; amendment proposed on #69. `trim/1` also narrows categories instead of only dropping keys, which is what takes M4 from 45.6% to 67.7% on real records. | #69, #70 |
| 2026-09-05 | S1 audited (grade A-) and fast-forwarded into `main`. A5 amendment accepted: the row now excludes lemmas Wiktionary files as Translingual (binomials) and measures 92.2 %; the raw 83.5 % and the 1,995 binomials stay reported. | #69 v7, #70 |
| 2026-09-05 | S1b: the record hash is taken on the payload as fetched, before trimming, so tightening what we keep never reads as a change at the source (19,250 false stamps reset once). Bare index rows that are only inflected forms yield to the word they inflect; a bare headword keeps its page only on an exact-case match. | #69 v7 open items, #70 |
| 2026-09-05 | S2: **L1 cannot reach 70 %** — only 68.1 % of the Animals scope has *any* concept link, because 6,840 of its lemmas have no English Wikipedia article at all (`soup-fin`, `trochid`, `prophaethontid`). 57.7 % clear the ≥ 0.8 bar. The QID rungs alone reach 25.2 %, so a corroboration step raises a title match when a taxon name, a QID rung or a gloss overlap agrees; both numbers are reported. Another rung cannot help: the words have no article. | #69 §7 L1, #70 |
| 2026-09-05 | S2: the two API sources use the **batched** endpoints (`wbgetentities`, 50 ids; the Action API, 20 titles) rather than #69 §2's pinned per-item URLs. 100,201 fetches became 7,380 requests and 1 h 37 m instead of ≈ 5.6 h, with redirect resolution, the disambiguation flag and `wikibase_item` included rather than inferred. The per-item URL stays as the record's link back. | #69 §2, #70 |
| 2026-09-05 | S2: a Wikipedia record is keyed by **the thing we asked about** — the probed lemma, or `concept:<QID>` — not by pageid. A lemma with no article has no pageid to key an absent marker on, and two lemmas legitimately redirect to one page. | #69 §4, #70 |
| 2026-09-05 | S2: `wikidata_taxon` grew the Animals scope from 21,277 to **25,393** lexemes. #69 §3's enwiki-sitelink requirement is applied (8,870 matched) and the count without it reported (9,290), because the article usually sits on the everyday concept rather than on the taxon item. | #69 §3, #70 |
| 2026-09-05 | S2 audited (grade A−). Accepted: L1 measured against the reachable set (articles exist), L3 and A10 over asserted links, L4 by lemma, A7 as "answered", records keyed by what was asked, batched endpoints, `name` as nominal, the corroboration pass with both numbers printed. Rule learned: when a scope grows, re-run the dictionary half too. | #69 v10, #70 |
| 2026-09-05 | Bierce source verified: Project Gutenberg #972 is the complete 1911 text and the only public-domain one (the 2000 *Unabridged* is a copyrighted compilation; Wikisource is the same text). Parse the **HTML edition** (`priv/sources/bierce/972-h.htm`), as the Rails app did: one paragraph per entry, verse in `<pre>`, attributions as short paragraphs. 959 entries + EUCHARIST, which the HTML mis-wraps. | #70 S3 notes |
| 2026-09-05 | S3: **Bierce holds 997 entries, not the 959 recorded** (or the 966 #69 A8 assumed). The single regex everyone had used misses 21 stubs whose whole definition is the verse below them, the six letter essays that open chapters I, J, K, T, W and X (chapter X is *only* that, and it was gluing itself to chapter W), `HABEAS CORPUS.`, `CUI BONO?`, `FORMA PAUPERIS.`, `LL.D.`, `R.I.P.`, and one missing comma in the 1911 source. The Rails seed is a cautionary baseline, not a reference: it never visits a `<pre>`, so it drops all 247 verse blocks and every attribution. | #69 §7 A8, #70 |
| 2026-09-05 | S3: for a source with structure, **`absorb/2` segments and `materialize/1` parses**. `raw` holds the entry's own markup; deciding which paragraphs, verse blocks and attribution lines belong to which entry needs the whole document, so it happens once, at absorb, as WordNet computes its inverse edges. The payoff is that a parser bug is fixed with `mix dd.materialize --source bierce --all`, network off, file never re-read — which is M2 in practice rather than in principle. | #69 §5, #70 |
| 2026-09-05 | S3: A8's "entries with `lexeme_id`" is **100 % by construction** — `materialize/1` creates the lexeme when the index lacks it, so an unattached entry cannot exist. The number that carries information is the **index hit rate**: 93.0 % of Bierce's headwords were words another source already attested, and the other 70 are words he invented (`WHANGDEPOOTENAWAH`). | #69 §7 A8 |
| 2026-09-05 | S3: **the Wikipedia lemma probe was never incremental.** It re-fetched all 23,784 scope lemmas on every run (90 minutes to learn nothing), and the disambiguation pass re-read all 1,775 "may refer to" pages with it — which is what restamped `changed_at` on 1,352 records in S2. Both now skip what they have already asked about; `--refresh` is the way back in. An expired absent marker is still retried. | #69 §5, #70 |
| 2026-09-05 | S3 audited (grade A). Accepted: A8 = 997 with the index hit rate as its informative metric; L1's reachable set computed by `Health.links/2` (82.5 % of 18,028); A1 pins an API by its last finished run; M2 read from `--all` runs; X3 as named probes. The scorecard has four statuses so it is complete from its first run. | #69 v11, #70 |
| 2026-09-05 | The first UI is a new build, not the skeleton's: Oatmeal theme applied and verified on a `/kit` page before any product page; the minimum use case is the hop between related words with Bierce first; layers that do not exist yet may be shown as clearly labelled samples in a dev-only fake-data mode; never commit the kit source. | #71 |
| 2026-09-06 | S4 audited (U0 A, S4b B+). Every page was driven in Chrome, not read from reports: the has/missing chips never applied (LiveView overwrites a `phx-value-value` on a `<button>` with the button's own empty `.value`) and `/health` ran a 4.5 s scorecard inside `mount/3`, which the 2.5 s long-poll fallback abandons, so two visitors loop on *Something went wrong*. Both go to a short **S4c**; the lesson is that a URL test is not a click test. |
| 2026-09-06 | **A5 v2.** The Translingual exclusion widens from the binomial regex to every scientific name at any rank (the lemma equals a linked concept's `taxon.scientific_name`): Wiktionary files *Archilochus*, *Paguridae* and *Therapsida* the way it files binomials, and the 85.0 % that sat exactly on the bar was those names counted as misses. Measured 93.0 %; bar raised to 90 %. |
| 2026-09-06 | Three UI rules. **Nothing slower than the long-poll fallback runs in `mount/3`** (heavy figures go to `assign_async`, cached). **Wikidata is not a word badge**: it never enters `lexemes.source_ids` because it attests concepts; pages show it as *linked* through `concept_links` and, on the word page, through the concept card. **Never use `value` as a `phx-value-*` key.** |
| 2026-09-06 | S5 planning. **A static source is a committed file when it is under about 10 MB compressed** (Johnson's LEME TEI-XML goes in gzipped, CC BY 4.0, pinned by edition and checksum); larger dumps stay in `data/` with a pinned checksum. **The extensibility rows are scored without footnotes:** S5a first makes the three hard-coded entry points generic and adds `mix dd.scope.new` over `priv/scopes/<slug>.json`, so E1 is one source row, one module, one registry line, fixtures and tests at zero migrations, and E2 is a scope with no code touched. |

---

## Naming

`devils_dictionary` stays as the internal/app name. The product needs its own name. Working title: **Wordhoard** (Old English *wordhord*, the poet's hoard of words; it says "aggregate" and gives the dead their due). Shortlist to react to: **Glossa** (a *gloss* is a short definition, which is exactly what we keep), **Marginalia** (the culture writing in the margins of the canon), **Polysemy** (many meanings, the thesis), **Necrolex** (too on the nose). Decide before the app. Note: the obvious `.com` / `.app` / `.io` domains for every name on this list were already registered on 2026-09-05, so the real brainstorm has to start from what is available.

---

## Licensing and attribution

| Source | License | We show |
|---|---|---|
| Wiktionary, Wikipedia, EB1911 (Britannica11) | CC BY-SA 4.0 | attribution + link on every card; derived text stays share-alike |
| Open English WordNet | CC BY 4.0 | attribution |
| Wikidata | CC0 | attribution anyway |
| Bierce, Johnson (LEME transcription CC BY 4.0), Webster 1913 (GCIDE, GPL package), Voltaire | public domain text | credit the transcription |
| Merriam-Webster, Datamuse | non-commercial API terms | attribution; never bulk |
| Urban Dictionary | unlicensed | on demand, attributed, linked, never stored in bulk or exported |

---

## Development

Toolchain is pinned in `.tool-versions` (Elixir 1.19 on OTP 28; `mise` picks it up automatically). Phoenix 1.8.13, LiveView 1.2.11, Oban 2.24, Req 0.7. Dumps live in `data/` (ignored). The old dev database from the skeleton still exists: run `mix ecto.drop` once before the first `mix ecto.create`. After S0:

```bash
mix setup                                  # deps, db, assets

mix dd.absorb wordnet                      # full corpus
mix dd.absorb wiktionary --index           # ~1.5M bare lexemes + forms
mix dd.scope.build animals                 # scope_lexemes, with reasons
mix dd.absorb wiktionary --scope animals   # senses, relations, trimmed raw
mix dd.resolve                             # relation targets, canonical variants

mix dd.absorb wikipedia --scope animals    # title probes → concepts, entries, images
mix dd.absorb wikidata --scope animals     # entities, taxonomy, the taxon bridge
mix dd.scope.build animals                 # again, WITHOUT --reset: adds wikidata_taxon
mix dd.absorb wikipedia --scope animals    # again: the lemmas the taxon rule added
mix dd.absorb wikidata --scope animals     # again: the QIDs those probes found
mix dd.absorb wikipedia --scope animals --concepts   # a summary for every concept (A7)
mix dd.link --scope animals                # the ladder → concept_links; prints L1

mix dd.absorb bierce                       # 997 entries, verse, cross-references
mix dd.resolve --source bierce             # his "See X" targets

mix dd.materialize --dry-run               # parity: raw vs derived, no network (M1)
mix dd.materialize --all                   # rebuild every derived row offline (M2)
mix dd.health                              # coverage, resolution, links, parity
mix dd.score                               # the MVP-0 scorecard, PASS/FAIL with actuals
mix phx.server                             # http://localhost:4000
```

Order matters three times. Wikidata is seeded from the QIDs the Wikipedia pass finds,
so Wikipedia goes first. The second `dd.scope.build` must **not** take `--reset`,
because reasons union and the taxon rule only ever adds. And the encyclopedia half
converges rather than running once: the taxon rule grows the scope, the new lemmas need
probing, and their pages name new QIDs — two rounds took it from 21,277 to 25,393
lexemes and the third round added 49, so two is enough in practice. Every pass is
incremental; a re-run costs only what it does not already have.

Conventions live in `AGENTS.md`. Every task prints numbers and writes an `import_runs` row. Tests run offline on checked-in fixtures for `cat`, `dog`, `oyster` and — for the two API sources — `seal`, which is a disambiguation page.
