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
| S1 Wiktionary + WordNet scoped, relations resolved | ⬜ |
| S2 Wikidata + Wikipedia, linking ladder, link rate | ⬜ |
| S3 Bierce, health, `dd.score` | ⬜ |
| S4 six pages | ⬜ |
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
- [ ] Design pass on the word page (#66): the tier styling *is* the joke
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
mix setup                      # deps, db, assets
mix dd.absorb wordnet          # then: wiktionary --index, scope.build animals, wiktionary --scope animals,
                               #       wikidata --scope animals, wikipedia --scope animals, bierce
mix dd.link --scope animals
mix dd.score                   # the MVP-0 scorecard, PASS/FAIL with actuals
mix phx.server                 # http://localhost:4000
```

Conventions live in `AGENTS.md`. Every task prints numbers and writes an `import_runs` row. Tests run offline on checked-in fixtures for `cat`, `dog`, `oyster`.
