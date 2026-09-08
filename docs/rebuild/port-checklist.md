# Port / rewrite / retire checklist — issue #74

The file-level inventory #74 asks for at the first checkpoint. Line counts are
deliberately absent: they are not effort estimates, and the issue says so.

Counted on `a2ef867`: 47 files under `lib/devils_dictionary`, 21 under
`lib/devils_dictionary_web`, 11 mix tasks, 48 test files (488 test blocks).

**Treatments.** *Reuse* — the file is correct against the new model and moves
unchanged or nearly so. *Port* — the shape is right, the table and column names
change. *Rewrite* — the logic survives, the code does not. *Retire* — deleted,
with what replaces it named.

## `lib/devils_dictionary/absorb`

| File | Treatment | Why |
|---|---|---|
| `absorb.ex` | Reuse | The registry map and `source_module/1`. Adding a source stays one line. |
| `absorb/source.ex` | Port | The six callbacks keep their shape; `materialize/1`'s **return map** changes, and its docs must say so. `trim/1`, `rate_limit_ms/0`, `absorb/2`, `enrich/2` are untouched. |
| `absorb/batch.ex` | Port | Keyset `Stream.unfold` over `Repo.stream` (a stream needs an enclosing transaction, which would destroy per-batch atomicity) is right and stays. The "needs materialization" predicate moves from `source_records.materialized_at` to the newest `source_record_revisions` row. |
| `absorb/gzip_lines.ex` | Reuse | Pure. The `strings: :copy` sub-binary warning stays load-bearing. |
| `absorb/clients/http.ex` | Reuse | 429 → `{:rate_limited, s}` → Oban `:snooze` rather than a blocking sleep is correct. |
| `absorb/clients/wikidata.ex` | Port | Add rank to the claim readers — today they return values regardless of rank, which is audit finding #8. |
| `absorb/clients/wikipedia.ex` | Reuse | `index/2`'s normalized+redirect walk is what canonical article identity will be built on. |
| `absorb/materializer.ex` | **Rewrite** | Keeps: local-key indirection, one `Ecto.Multi` per batch, `@chunk 2_000`, in-process `uniq_by`, "every `on_conflict` UPDATEs, never `:nothing`". Gains: revision insertion instead of in-place upsert, and **output reconciliation** by `last_seen_run_id` (audit finding #1). |
| `absorb/resolver.ex` | **Rewrite** | The windowed `UPDATE … FROM (SELECT DISTINCT ON …)` and the preference order (stated pos → exact case → `@pos_priority` → oldest id) survive as an algorithm. The two-lexeme cycle check is replaced: it misses simultaneous updates, which is why five reciprocal canonical pairs exist. |
| `absorb/linker.ex` | **Rewrite** | All six rungs, all four corroboration steps and their measured justification survive. Two policy changes: a rerun may not resurrect a `rejected` link, and `title_match`/`disambiguation` become `lexeme_entity_candidate`, not `refers_to`. |
| `absorb/scope_builder.ex` | **Rewrite** | Three rules survive; a fourth (`explicit_lemmas`) is added for `culture`. `{:skip, reason}` over a silent zero stays. |
| `absorb/sources/wordnet.ex` | Port | Parser reused. `resolve_targets/1`'s in-absorb SQL is rewritten. |
| `absorb/sources/wiktionary.ex` | Port + **policy fix** | Parser, `trim/1`, the index pass and the 2 M-line truncation guard reused. `external_id` stops being `word/pos/etym#position` — audit finding #2. |
| `absorb/sources/wikidata.ex` | Port + **policy fix** | Rank policy; retain statement id and needed qualifiers/references. |
| `absorb/sources/wikipedia.ex` | Port + **policy fix** | Probe stays evidence; the article gets canonical publication identity — audit finding #4. |
| `absorb/sources/bierce.ex` | Port | The four headword regexes, the segment/parse split and the 997-entry result are all correct; only the output map changes. |
| `absorb/sources/johnson.ex` | Port | Same. `verify!/2` generalises into `Sources.Manifest`. |

## `lib/devils_dictionary` — domain

| File | Treatment | Why |
|---|---|---|
| `sources.ex` | **Rewrite** | `record_conflict/0`'s `IS DISTINCT FROM content_hash` becomes "insert a revision when the checksum differs". Run bookkeeping is reused. |
| `sources/source.ex` | Reuse | Tier/kind/access/licence stay here and only here. |
| `sources/source_record.ex` | **Rewrite** | Splits into `SourceRecord` (identity) + `SourceRecordRevision` (payload). `content_hash/1`, taken before `trim/1`, becomes `revision_key`. |
| `sources/import_run.ex` | Port | Gains `source_input_id`. |
| `sources/person.ex` | **Retire** | Replaced by `entities(entity_kind: "person")` + `person_details`. |
| `sources/catalog.ex` | Port | **Fix the Bierce QID (`:196`, Q310190 → Q191050).** `people/0` becomes entity seeds; the adapter callbacks for trim lists stay. |
| `sources/manifest.ex` | **New** | Done at P0. |
| `lexicon/lexeme.ex` | Port | `slug` stops being identity; `lexical_key` starts being it. |
| `lexicon/sense.ex` | **Rewrite** | Splits into `Sense` + `SenseRevision`. |
| `lexicon/entry.ex` | **Retire** | Replaced by `content_items` + `content_revisions` + `defines`/`about`/`authored_by`/`published_in`. |
| `lexicon/lexical_relation.ex` | **Retire** | Replaced by assertions on source-native lexical predicates. |
| `lexicon/scope.ex`, `scope_lexeme.ex` | Port | FK moves to `lexemes.object_id`. |
| `lexicon.ex`, `lexicon/browse.ex` | Port | `lookup/2`'s three steps survive; the `%` trigram operator (43 ms vs `similarity() > 0.3`'s 420 ms) is load-bearing and stays. |
| `lexicon/word_page.ex` | Port | The seven-query shape, the per-sense placement rule, the caps and the card-addressed provenance drawer all survive. |
| `encyclopedia/concept.ex` | **Retire** | Replaced by `entities`; `qid` moves to `external_identifiers`. |
| `encyclopedia/concept_link.ex` | **Retire** | Replaced by `refers_to` / `lexeme_entity_candidate` assertions. |
| `encyclopedia/concept_relation.ex` | **Retire** | Replaced by assertions on `parent_taxon`/`subclass_of`/`instance_of`. |
| `encyclopedia.ex` | Port | The recursive CTEs and the chain rule (taxon → subclass-of → instance-of at the first step only, one parent per step) survive. |
| `health.ex`, `health/coverage.ex` | Port | Column names change. |
| `health/parity.ex` | **Rewrite** | Natural-key presence becomes semantic equality. It must fail on `CORRUPTED`; today it does not. |
| `health/pages.ex` | Port + extend | X1 gains a routing assertion. |
| `health/score.ex` | Port + **revise E1/E3/M1/M2/X1/L1/U3/U6** | See `score-rows.md`. |
| `demo.ex`, `markdown.ex`, `repo.ex`, `application.ex` | Reuse | The demo seam downstream of `WordPage.build/2` stays exactly where it is. |
| `workers/*.ex` | Port + **guard** | Gain Oban uniqueness (audit finding #5). |

## `lib/devils_dictionary_web`

| File | Treatment |
|---|---|
| `router.ex` | Port + extend: `/words/:id/:slug`, `/entities/:id/:slug`, connection detail, composer; `/admin/imports` and `/health` behind auth. |
| `components/kit.ex` | Reuse. Tier glyph and tier class unchanged. |
| `components/word.ex`, `thing.ex`, `provenance.ex` | Port. The two rules — never `phx-value-value`, every element has a stable id — stay. |
| `components/demo.ex`, `layouts.ex`, `core_components.ex` | Reuse. |
| `live/word_live.ex` | Port. Nothing slower than the long-poll fallback in `mount/3`. |
| `live/{home,scope,source,health,kit}_live.ex` | Port. |
| `live/admin/imports_live.ex` | Port + guard. |
| **New** | entity page, work page, connection detail, connection composer. |

## `lib/mix/tasks`

Eleven tasks port. Five are new: `dd.manifest` (done), `dd.export.replay`,
`dd.reset`, `dd.spike`, `dd.rebuild`.

## `test`

| Group | Files | Treatment |
|---|---|---|
| Pure parser + client tests | 10 files, ~159 tests | **Reuse untouched.** They are the reason the parsers can be kept, and they are the regression net for every parser fix. |
| `support/word_fixtures.ex` | 1 | **Rewrite.** It writes raw structs, so it is the single highest-leverage file in the suite. |
| `support/{fixtures,fake_source,data_case,conn_case}.ex` | 4 | Port. The 40 verbatim JSON fixtures and `MANIFEST.json` are reused as-is. |
| `schema_test.exs` | 1 | **Rewrite** as the new schema's contract, plus the direct-write rejection proofs. |
| Read-path (`word_page`, `lexicon`, `browse`) | 3 | Port; keep the query-count assertions. |
| Web | 11 | Port; add the connected-flow tests. |
| Health | 7 | Port; parity's tests change most. |
| Absorb write-path | 8 | Port. |
| Demo | 3 | Reuse. `demo_inert_test.exs` reads `config/prod.exs` off disk — keep. |

## Docs

`docs/sketches/community_layer_migration.exs` is **retired**, and with it the six
places that reference it: `docs/sketches/README.md`, `README.md` (three rows),
`docs/map/README.md`, `lib/devils_dictionary/demo.ex`,
`lib/devils_dictionary_web/components/demo.ex`, and `health/score.ex:693`.
