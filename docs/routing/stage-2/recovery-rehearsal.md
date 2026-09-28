# Stage 2A — recovery rehearsal on the development corpus

**27 September 2026**, for [routing issue #194](https://github.com/razrfly/dictionary/issues/194). A rehearsal of the [recovery procedure](../recovery.md) on the full development corpus, before any persistent backfill.

> **Superseded in part by the [recovery repair](recovery-repair.md).** The repair fixed the crashes and defects found here and re-ran recovery with routing and curation state. It also corrects one count below. 1,226 Wikidata items have no English label, but the materializer also reads `mul` labels (1,218 of them) and taxon names (2), so only 6 have no name it can use, not 1,218.

- **Source:** `devils_dictionary_v2`, 14 GB, 28.6 million rows. It still predates the routing migration.
- **Working databases:** isolated copies in a disposable scratch PostgreSQL 18.2 cluster.
- **Untouched:** the source's data and schema. No backfill, route, reader or publication change was made.

Raw evidence (dumps, manifests, logs, timings) is kept locally and is not published. This report gives the outcome, the commands and the fingerprints.

## Result

| Gate | Result |
|---|---|
| The corpus restores exactly at its original, pre-routing schema | **Pass** |
| The routing migration, applied to a copy, preserves the captured corpus | **Pass** |
| Nonempty routing state survives a second snapshot and restore exactly | **Pass** |
| Supported re-projection preserves identities and routing state | **Pass**: objects, lexemes, all six routing tables and every resolution exact |
| …with only the documented bookkeeping differing | **Fail**: pre-existing drift; see [Findings](#findings) |
| Ledger and resolver operations work after recovery | **Pass** |
| The frozen baseline stays unchanged throughout | **Pass**: 52 sections, zero differences at the end |

Recovery of identity and routing is proven at corpus scale. Re-projection is not yet a clean round trip on this corpus, for reasons that predate routing. The Stage 2 recovery gate stays open until it is.

## What was done

1. **Preflight.**
   - **Source schema:** last migration `20260924222346`, none of the six routing tables.
   - **Ownership:** owned by `postgres`, with no custom object, schema or default privileges.
   - **Encoding:** UTF8, ICU `en-US`.

   The usual server's disk had 8 GB free, less than one copy needs. The owner chose a disposable scratch cluster on another drive, for the copies and dumps only: same PostgreSQL build, same encoding and locale, port 5433.
2. **Recover the corpus unchanged.**
   - **Write-free window:** the source's two writers were suspended for about 4 minutes, and resumed once the comparison passed. Its insert, update and delete counters were equal before the snapshot and after the comparison.
   - **Snapshot:** 80 s; the dump is 1.26 GB.
   - **Restore:** into the baseline copy at the same schema, in 76 s.
   - **Verification:** `mix dd.routing.verify` against the source took 73 s. Every section matched exactly, the schema and every sequence's state included. Routing was reported **not applicable**: both databases predate the migration, so this proves corpus recovery only.
3. **Exercise routing on the copy.**
   - **Migration:** the routing migration was applied to the baseline copy only. [`migration_check.exs`](rehearsal/migration_check.exs) proved it left all 43 pre-existing table sections byte-identical (28,624,590 rows). It added:
     - one migration row;
     - the six routing tables, empty;
     - six unused sequences;
     - 283 schema rows, all belonging to routing objects.
   - **Fixture:** [`fixtures.exs`](rehearsal/fixtures.exs) wrote a marked routing history through the supported APIs, covering every routing table and every operation:
     - 12 pages, 14 reserved paths, 42 ledger rows, 12 decisions (one a human override), 3 revisions and 5 memberships;
     - operations: allocate 12, move 2, merge 1, split 1, retire 2, restore 1, rollback 1.

     It touched only its own 12 marked objects, and the corpus rows that registry merges, splits and actors add.
4. **Recover nonempty routing state.**
   - The baseline was frozen (`default_transaction_read_only`) and snapshotted in 82 s.
   - It was restored into a second copy in 77 s.
   - `mix dd.routing.verify` from that copy against the frozen baseline took 84 s. It matched exactly: every corpus section, all six routing tables, 1,601 schema rows and 37 sequence states. Every path and page resolves the same.
5. **Re-project, reversed provider order.** The routing working copy exported its own Wikipedia and Wikidata records. The provider order was reversed from the rebuild's:
   1. `mix dd.replay` for Wikipedia (85,044 records), then Wikidata.
   2. `mix dd.materialize --all` for wikipedia, wikidata, johnson, bierce, wiktionary (1,485,718 records) and wordnet.
   3. `mix dd.resolve`, a pass the runbook omitted.
   4. `mix dd.routing.verify --projected` against the frozen baseline.

   Outcome:
   - **Identities and routing held:** objects, lexemes, all six routing tables and every resolution stayed exact.
   - **Clean sources:** Johnson, Bierce, Wiktionary and WordNet re-projected with M2 identical.
   - **Failures:** the Wikidata replay and Wikidata's `materialize --all` crashed. Wikipedia's `materialize --all` changed derived state, and ten corpus sections differ. Every difference is explained under [Findings](#findings).
6. **Operations after recovery.** A fresh copy of the frozen baseline was restored and verified exactly (restore 110 s, verification 83 s). Then [`operations.exs`](rehearsal/operations.exs) ran on it:
   - All 11 recovered fixture paths resolve as expected, covering canonical, alias redirect, merge redirect, split choice, tombstone (gone), restored, rolled-back move and an On page.
   - On new marked scratch pages, allocation, move (the old path becomes an alias) and rollback all work, with page and path ids continuing the restored sequences.
   - A batch allocation of a tombstone is refused.

## Timings and sizes

| Operation | Time | Size |
|---|---:|---:|
| Manifest of the live source (read-only dry run) | 69.5 s | 28.6 M rows, 46 sections |
| Snapshot of the source (`mix dd.snapshot`) | 80 s | 1.26 GB dump |
| Restore into the baseline copy (`--jobs 8`) | 76 s | 9.45 GB database (source: 14 GB) |
| Exact verification, source against copy | 73 s | |
| Migration check (capture, then compare) | 65 s + 65 s | |
| Routing migration on the copy | 1 s | |
| Snapshot of the routing baseline | 82 s | 1.26 GB dump |
| Restore into the working copy | 77 s | |
| Exact verification, working copy against baseline | 84 s | |
| Materialize `--all`: wikipedia, wikidata, johnson, bierce, wiktionary, wordnet | 327, 155 (crashed), 316, 301, 791, 386 s | |
| `mix dd.resolve` | 55 s | |
| Projected verification | 79–88 s | |

Most of `materialize --all` on the small sources is its M2 fingerprinting of the whole corpus. The scratch cluster held three copies in 39 GB.

The usual server's disk was 99% full at the start, and fell further during the session from other activity. A copy cannot be restored there until space is freed.

## Fingerprints

| Artifact | SHA-256 |
|---|---|
| Source dump (1,257,505,578 bytes) | `685e4592548dfd657f33676de0ee062140be4fb8d7be3578f6b9b7aeea42ea46` |
| Routing baseline dump (1,257,579,151 bytes) | `3d2a993e6fc8627df36631de0b09b387aca7dee08bcd5205505cf2c8c385a456` |

Each dump's sidecar records its source's server, port, name and routing digest. The dumps, the replay archives and the full evidence (logs, manifests, row diffs) are kept locally for review.

## Reproduce

The commands, with the scratch cluster on port 5433 and `SCRATCH` for its directory. Every script under [`rehearsal/`](rehearsal/) refuses anything but a `devils_dictionary_stage2a_*` copy off the usual server.

```bash
mix dd.snapshot --out "$SCRATCH/dumps/v2-source.dump"
```

```bash
DD_DATABASE=devils_dictionary_stage2a_baseline DD_DATABASE_PORT=5433 mix dd.snapshot --restore "$SCRATCH/dumps/v2-source.dump" --database devils_dictionary_stage2a_baseline --jobs 8
```

```bash
DD_DATABASE=devils_dictionary_stage2a_baseline DD_DATABASE_PORT=5433 mix dd.routing.verify --baseline ecto://postgres:postgres@localhost:5432/devils_dictionary_v2
```

```bash
DD_STAGE2A_REHEARSAL=1 DD_DATABASE=devils_dictionary_stage2a_baseline DD_DATABASE_PORT=5433 mix run --no-start docs/routing/stage-2/rehearsal/migration_check.exs capture BEFORE.bin
```

```bash
DD_DATABASE=devils_dictionary_stage2a_baseline DD_DATABASE_PORT=5433 mix ecto.migrate --to 20260926193256
```

The rehearsal ran when main's last migration was the routing one. `--to` pins that routing-only boundary: without it, today's main would also apply #206's curation migrations.

```bash
DD_STAGE2A_REHEARSAL=1 DD_DATABASE=devils_dictionary_stage2a_baseline DD_DATABASE_PORT=5433 mix run --no-start docs/routing/stage-2/rehearsal/migration_check.exs compare BEFORE.bin REF_BEFORE.bin REF_AFTER.bin CHECK.json
```

`REF_BEFORE.bin` and `REF_AFTER.bin` are captures of an empty reference database, migrated `--to 20260924222346` and then `--to 20260926193256`. The rehearsal itself compared against a stricter, routing-only rule written into the script. It has since been replaced by this reference-derived check, which also serves current main; see [the runbook](../recovery.md).

```bash
DD_STAGE2A_REHEARSAL=1 DD_NO_OBAN=1 DD_DATABASE=devils_dictionary_stage2a_baseline DD_DATABASE_PORT=5433 mix run docs/routing/stage-2/rehearsal/fixtures.exs FIXTURES.json
```

Then freeze the baseline with `ALTER DATABASE … SET default_transaction_read_only = on`, snapshot it and restore it into `devils_dictionary_stage2a_working`, as above.

```bash
DD_DATABASE=devils_dictionary_stage2a_working DD_DATABASE_PORT=5433 mix dd.routing.verify --baseline devils_dictionary_stage2a_baseline
```

Re-projection runs on the working copy with `DD_NO_OBAN=1 DD_DATABASE=devils_dictionary_stage2a_working DD_DATABASE_PORT=5433`:
1. `mix dd.export.replay --source S --out DIR`, for S = wikipedia, then wikidata.
2. `mix dd.replay --dir DIR --source S`, in the same order.
3. `mix dd.materialize --source S --all`, for S = wikipedia, wikidata, johnson, bierce, wiktionary, wordnet.
4. `mix dd.resolve`.
5. `mix dd.routing.verify --baseline devils_dictionary_stage2a_baseline --projected`.

Operations run on a fresh verified copy: `operations.exs FIXTURES.json OPERATIONS.json`.

## Findings

**1. The source's writers must be stopped by their owners when they run in a terminal.** The capture suspended the source's two writers with `SIGSTOP` and resumed them with `SIGCONT`.
- The non-interactive preview server resumed normally.
- The interactive development server (`iex -S mix phx.server`) did not. It was a foreground terminal job, so its shell took the terminal back. After `SIGCONT` it read the terminal as a background job and stopped again. Its state is intact, but it serves nothing until `fg` is typed in its terminal.

The [runbook](../recovery.md) now says to stop such a server through its owner.

**2. Re-projection is not a clean round trip on this corpus.** The causes predate routing.

| | Difference against the frozen baseline | Cause |
|---|---|---|
| a | The Wikidata replay crashes: a NULL `external_identifiers.external_id` | 330 quotation-verifier cache records (`enwikiquote-sitelink:…`, `gutenberg-works:…`) are stored in the `wikidata` source. The entity materializer treats every record there as an entity. |
| b | Wikidata `materialize --all` crashes: `:label_required` | 1,218 label-less Wikidata entities were materialized by the original build (5–11 Sep). The source-identity rules added on 12 Sep refuse them. |
| c | 471 entities gain `metadata.source_identity_evidence`; 471 identifiers are re-pinned; +471 provenance outputs; 142 entities go from concept to work (+142 `work_details`); +329 `person_details`; +36 `instance_of` assertions; +1 actor | Today's Wikidata materializer, in the batches it committed before crash (b). The corpus predates these rows and fields. |
| d | 23 entities' image metadata | Today's Wikipedia materializer. |
| e | 2.48 M re-created pending edges | The runbook omitted `mix dd.resolve`. With it, `pending_relations` is back to its 163,537 rows and their ids. |
| f | 388 pending edges and 2,496 relation revisions carry new provenance, such as `{"sense": …}` → `{"source": "Thesaurus:cat"}`; the M2 fingerprint does not cover `pending_relations` | Today's Wiktionary materializer records Thesaurus-derived edges differently. |

No object was created or removed, no routing row changed, and every path and page resolved the same throughout.

## Next bounded step

Before any persistent backfill, make re-projection a clean round trip. This is one bounded piece of work, with three decisions for the owner:
1. **Verifier caches.** Keep the quotation verifier's cache records out of the Wikidata entity materializer: skip payloads without an entity `id`, or store the caches under their own source.
2. **Corpus drift.** Decide how the corpus catches up with today's materializers. Either do a deliberate, reviewed re-materialization of the live corpus, source by source, with the differences above approved as intended; or make the materializers reproduce what the corpus already holds. This includes the 1,218 label-less Wikidata entities.
3. **The M2 check.** Extend it to `pending_relations`, so a materializer change cannot pass as identical.

Then re-run step 5 of this rehearsal with the committed scripts. The Stage 2 gates after that are unchanged: repeat-run identity preservation and crash/resume on a disposable copy, then the owner's decisions on the population and reviewers.
