# Stage 2 recovery repair — report

**27 September 2026**, for [routing issue #194](https://github.com/razrfly/dictionary/issues/194). This is the author's evidence for the first Stage 2 checkpoint. It repairs what the [independent Stage 2A audit](https://github.com/razrfly/dictionary/issues/194#issuecomment-5855977848) found, then re-runs recovery on the full development corpus with routing and curation state. The grade is the independent reassessment's to give.

- **Source:** `devils_dictionary_v2`, only read. Its data and schema are untouched by this work.
- **Copies:** isolated databases in the disposable scratch cluster (PostgreSQL 18.2, port 5433) on another drive, as in [Stage 2A](recovery-rehearsal.md). No storage was relocated.
- **Not done here:** no backfill, reader, publication, merge or source change.

Raw evidence (dumps, manifests, logs, row-level deltas) is kept locally.

## Result

| Requirement | Result |
|---|---|
| A restore refuses the database its snapshot came from, however it is reached | **Pass**: identity from the server, not from names |
| Migration history decides whether a database predates routing | **Pass** |
| Migrations checked against a reference, at the pinned routing boundary and at current main | **Pass**: on real migrations in tests, and on the corpus |
| Verifier caches told from Wikidata entities; nameless items kept | **Pass**: 330 caches and 6 nameless items reported by kind, none skipped silently |
| M2 covers pending relations, with `--resolve` as the boundary | **Pass** |
| Replay, materialization and resolution complete for every provider | **Pass**: every record of all six providers |
| Identities, references, routing history and curation approvals preserved | **Pass**: exact in every run |
| Against the frozen baseline, only bookkeeping differs | **Not yet**: a measured catch-up remains; [proposal](corpus-catch-up.md) awaits the owner |
| Normal operations on the same projected copy | **Pass** |
| The caught-up state is a fixed point of today's code | **Pass**: two full repeats, every step exit 0, exact against it ([Stability](#stability)) |

The recovery gate stays open until the owner decides on the [corpus catch-up](corpus-catch-up.md) and the reassessment accepts the evidence.

## Repairs

| Commit | What |
|---|---|
| `aec0c6b` | **Restores are tied to server identity.** The sidecar records the cluster's `system_identifier`, the database's name and oid, and the dump's size and SHA-256. A restore refuses when the sidecar is missing, malformed or legacy, when the dump is not the one the sidecar describes, when the target's identity cannot be read, and when the target is the source. Refusal comes before anything is dropped. **Routing state is judged by migration history**: a recorded routing migration without its tables, tables without the migration, or no history all fail as inconsistent. **Migration checks derive their expectations from a reference database** migrated over the same range. The verify task opens its own connections and refuses to compare a database with itself. Documentation and both review findings on PR #208. |
| `e67bbec` | **Wikidata caches are not entities.** The quotation verifier's lookups (`Sources.CacheRecord`) are reported as `verifier_cache`. An id-less payload that is not a registered cache is refused. **Nameless items keep their established entity** and are reported as `label_missing`. **M2 fingerprints `pending_relations`**, and `mix dd.materialize --all --resolve` brackets the resolve pass. |
| `2d495e8` | The rehearsal fixture carries **curation approvals**: a real word's composition, accepted and published, and a second version rejected. The operations check them and exercise replay, refusal, withdrawal and republication. |
| `53665c5` | The runbook and `RecoveryTest` re-project with `--resolve`. **A replay records what it materialized**; it used to print sense counts, so a Wikidata replay that projected 531 records read "materialized 0". |
| `145113c` | **Re-materialization no longer retires a minted creator's evidence** ([finding 2](#findings)). |
| `899aaaf` | **A claim several records attest is resolved from one attestation, chosen before any is drained** ([finding 3](#findings)). |
| `233c7e5` | From an internal review. **A failed snapshot leaves its predecessor restorable**: the dump and the sidecar are each renamed into place only when complete. **The probe, the drop and `pg_restore` reach one endpoint**, settled as Postgrex settles it, and a `socket:` or `endpoints:` config is refused. **A dump whose sidecar is missing or legacy may restore into a database that does not exist yet**, where nothing is dropped, so an older snapshot stays usable as a rollback point. |
| `fb9392f` | From the same review. **The speaking attestation is chosen by content, not id**: by the record's external id, then the stated part of speech, metadata and method. Ids say only who was inserted first. **Each resolve window is sent only its own claims.** A replay test asserts real counts. Three limits are documented. |

## What was done

1. **Capacity.** The usual drive had about 5 GB free; the scratch cluster's drive 1.7 TB. Each copy is about 9.5 GB.
2. **Capture.** The source's row counters (`pg_stat_user_tables`) were equal at 13:29:29 and 13:33:18 UTC, before the snapshot and after the comparison: the window was write-free. The snapshot took 85 s and wrote a format-2 sidecar.

   The source was no longer pre-routing. At 13:11 UTC, another session had applied the routing and curation migrations to it, and two migrations from an unmerged branch ([finding 1](#findings)). Every one of those tables was empty.
3. **Restore and verify.** The copy was restored in 77 s. It matched the source exactly in 67 s: 69 sections, including the schema and 54 sequence states. Routing was present and empty on both sides.
4. **Migration checks.**
   - **Tests.** `MigrationCheckTest` runs the real migrations on disposable databases, to the pinned routing boundary (`--to 20260926193256`) and to current main.
   - **Corpus scale.** A copy of Stage 2A's frozen baseline was migrated to main. It holds the corpus at the routing boundary, plus 2A's routing history. Against an empty reference migrated over the same range, it kept all 49 pre-existing tables unchanged (28,624,718 rows). It added exactly the reference's 2 curation migrations, 13 tables and 474 schema rows.
5. **Fixture, freeze, snapshot.** The fixture was dry-run on a template copy, then written to the base copy:
   - routing: 12 pages, 14 paths, 42 ledger rows and 12 decisions, covering every operation;
   - curation: *abasement* (noun), its Bierce entry leading and Johnson's definition as a highlight, accepted and published by a marked reviewer, with a second version rejected.

   The base copy was frozen (`default_transaction_read_only`) and snapshotted in 81 s as **B0**, the frozen baseline. W1 was restored from it and matched it exactly.
6. **First measurement, at `2d495e8`.** A full projection of W1 completed for every provider without a crash. It found the two defects fixed in `145113c` and `899aaaf`. That run is superseded; its copy is kept locally as evidence.
7. **P1, at `fb9392f`.** B0 was restored into P1, which matched it exactly, and then projected: Wikipedia and Wikidata each replayed from an archive exported from P1 itself, then `materialize --all --resolve` for six providers. The outcome is in the next table; [Projection against B0](#projection-against-b0) gives the delta.

   The same chain first ran at `899aaaf`, including two stability runs, which passed. The internal review's changes then required running it again at `fb9392f`, so those earlier results are superseded and kept locally as evidence.
8. **Operations on P1**, the same projected copy, after the delta was measured:
   - all 11 recovered routing paths resolve as expected: canonical, alias and merge redirects, split choice, tombstone, restored, rolled-back move, and an On page;
   - allocation, move and rollback work on a new page, with ids continuing the restored sequences, and a batch refuses to reallocate a tombstone;
   - the curation composition still stands as approved, with nothing withheld: its lead and highlight are the same content revisions as before projection;
   - the original publication's key replays its own receipt, the rejected version cannot be published (`:not_approved`), and withdrawing and republishing work, with receipts continuing the restored sequence.
9. **C1.** P1, before its operations, was snapshotted, restored into C1, verified exact against P1, and frozen: the caught-up state. See [Stability](#stability).

| P1 step (from B0) | Records | Exit | Notes |
|---|---:|---:|---|
| replay wikipedia | 85,044 | 0 | nothing stale |
| replay wikidata | 73,338 | 0 | materialized 531; 330 `verifier_cache` not projected |
| materialize wikipedia | 85,044 | 1 | M2 changed: `entities` |
| materialize wikidata | 73,338 | 1 | M2 changed: 8 tables; 330 `verifier_cache`, 6 `label_missing` |
| materialize johnson | 42,726 | 0 | identical; 906 edges resolved |
| materialize bierce | 997 | 0 | identical; 9 edges resolved |
| materialize wiktionary | 1,485,718 | 1 | M2 changed: `assertion_revisions`, `pending_relations`; 2,475,210 edges resolved |
| materialize wordnet | 120,564 | 0 | identical |
| `verify --projected` against B0 | | 1 | 57 sections exact; 10 differ, all attributed below |

An exit of 1 from `dd.materialize` here means the run completed, recorded its stats, and found derived state changed. Nothing crashed.

## Projection against B0

Exact: `objects`, `lexemes`, senses, content, all six routing tables, all thirteen curation tables, and every path and page resolution.

The rest was measured row by row. Only the bookkeeping `mix dd.routing.verify --projected` leaves out was excluded (`updated_at`, `materialized_at`, `last_seen_run_id`). **Nothing was removed from any table**, no object was minted, and no external identifier's value, object or status changed. What was added and changed is today's code catching up with a corpus built by older code: Wikidata source identity, sharper kinds and detail rows, creator identities projected for the first time, Wiktionary edge provenance, and Wikipedia's current images for 23 artworks. The [catch-up proposal](corpus-catch-up.md) gives the counts, causes and examples. Applying it to the source is the owner's decision.

## Stability

C1 is P1 before its operations, frozen: the caught-up state. Two further copies, P2 and P3, were each restored from C1's snapshot, matched it exactly, and were projected in full by the same commands, side by side.

| Step | P2 | P3 |
|---|---|---|
| restore, then exact verify against C1 | 0, 0 | 0, 0 |
| replay wikipedia, wikidata | 0, 0; nothing stale | 0, 0; nothing stale |
| `materialize --all --resolve`: wikipedia, wikidata, johnson, bierce, wiktionary, wordnet | all 0; M2 identical for every one | all 0; M2 identical for every one |
| dispositions | wikidata: 330 `verifier_cache`, 6 `label_missing` | the same |
| `verify --projected` against C1 | 0: 67 sections exact, every resolution the same | the same |
| `operations.exs` on the same copy | pass | pass |

M2 compares every table the fingerprint covers, `pending_relations` included, after the resolve pass. So re-projecting the caught-up corpus with today's code changes nothing derived. The routing fixture and the curation composition, standing as approved, came through both runs, and their operations passed. The same pair of runs also passed at `899aaaf`, before the internal review's changes.

## Findings

**1. The source was migrated by another session during this work.** At 13:11 UTC, `devils_dictionary_v2` received:
- the routing migration and #206's two curation migrations;
- `20260927114948` and `20260927131023` from `codex/runtime-195-stage-a` (#195, PR #210), which is unmerged.

The latter add four empty tables for the curation runtime, which nothing here reads or writes. This branch has no files for those two versions; `mix ecto.migrations` lists them as `** FILE NOT FOUND **`. So the accepted baseline carries a schema from an unmerged branch. The owner should know. Whether to keep it is the owner's call; nothing was rolled back.

**2. Re-materialization retired a minted creator's evidence.** The creator-identity flow (#164) records each mint as its Wikidata record's `entity` output, keyed by the bare QID. No materializer emits that key. So `Materializer.reconcile/2`, which retires a visited record's outputs that the run did not re-stamp, retired all 201 of them on the records' first materialization:
- 200 gained a source-identity output beside it;
- one organization, DK (Q1245484), was left with no live output at all.

A later mint would have restored the output, and the next materialization retired it again. `Creators.minted_output/0` now names that output, and `reconcile` leaves it alone. Regressions in `BatchTest` and the Wikidata dispatch test fail without the fix.

**3. Claims attested by several records churned on every re-projection.** Wiktionary keys a record by etymology, so one edge can be attested several times with different provenance. `cat/noun/1`, `/2` and `/3` all make *calico cat* a hyponym of *cat*: one cites the sense, another the Thesaurus page. The resolver wrote each chunk's first attestation in pending-id order. A full re-projection therefore revised such a claim twice and ended where it started: nine claims in the first measurement, and M2 could never be identical for Wiktionary.

The resolver now chooses one attestation over every pending row, before any is drained. It chooses by content: the first attesting record by external id, then the stated part of speech, the metadata and the method. The internal review caught that an earlier version chose by record id, which reflects only insertion order (`fb9392f`). That attestation supplies the claim's metadata, method and confidence, and its stated part of speech picks the target. The regressions fail without the fix. Chosen by content, it matches what the build kept for all but one claim, which is part of the catch-up.

**4. The replay reported the wrong count.** Its "materialized" line summed senses, so a Wikidata replay that projected 531 records read 0. It now reports records, passes and dispositions, and records them in the run's `import_runs` stats.

**5. Correction to the Stage 2A report: 6 nameless items, not 1,218.** Of the 1,226 Wikidata records without an English label, 1,218 carry a `mul` label and 2 a taxon name, both of which the materializer reads. The 2A crash came from the 6 with no name at all: 1 person and 5 concepts, among them a film and a TV series. All 6 are established entities, named by other sources. They are now reported as `label_missing`, and their entities keep their names.

**6. An internal review, before delivery.** A read-only review of the code commits found:
- the snapshot and endpoint defects fixed in `233c7e5`;
- the id-ordered attestation choice fixed in `fb9392f`.

It also noted limits that are documented rather than changed:
- canonical linking in the resolve pass spans every source;
- a migration that backfills existing rows cannot be judged against an empty reference;
- a nameless item's earlier source-identity output is retired;
- the resolve pass should run with background jobs off, as a re-projection does.

Parity's dry run (`mix dd.materialize --dry-run`) counts any live output other than a sense or content item as unretired. So it lists the minted creators' kept outputs, as it already listed source-identity outputs; that report is unchanged in kind.

**7. Service state.** The development server on port 4007 is still stopped, as Stage 2A left it (`SIGTTIN`). It needs `fg` in its own terminal. Another session's preview on port 4017 holds idle connections to the source; it wrote nothing during the capture window.

## Timings and fingerprints

| Operation | Time |
|---|---:|
| Snapshot of the source / of a copy | 81–89 s |
| Restore (`--jobs 8`) | 77–164 s; the longer when two ran at once |
| Exact verification | 67–95 s |
| Migration check (capture, then compare) | 73 s + 66 s |
| Replay wikipedia / wikidata | 5 s / 9–13 s |
| Materialize `--all --resolve`: wikipedia, wikidata, johnson, bierce, wiktionary, wordnet | 342, 393, 324, 307, 799, 374 s |
| Projected verification | 76–81 s |

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| Source capture | 1,257,710,161 | `a9384f4449283ad416adc4ff102791dd25a1a6811f87f23be207c613d93ffc00` |
| B0, the frozen baseline with the fixture | 1,257,715,552 | `8090988c2ef2ff65bbd394cebb9ba06311b1d21de3e969bcf6aabd2f8e246230` |
| C1, the caught-up state | 1,257,193,897 | `b78aa6c8fec0cf9f87fea9b2b284307286ebd887db384fa42354df0683dfee34` |

## Reproduce

The rehearsal scripts under [`rehearsal/`](rehearsal/) refuse anything but a `devils_dictionary_stage2*_*` copy off the usual server. Each needs `DD_STAGE2_REHEARSAL=1`, and every write also needs `DD_NO_OBAN=1`. With `DD_DATABASE_PORT=5433` and `DD_DATABASE` naming the copy:
1. `mix dd.snapshot --out DUMP` on the source.
2. `mix dd.snapshot --restore DUMP --database COPY`.
3. `mix dd.routing.verify --baseline ecto://postgres@localhost:5432/devils_dictionary_v2`.
4. Migration checks: `migration_check.exs capture` and `compare`, against a reference migrated with `mix ecto.migrate --to` (see [the runbook](../recovery.md)).
5. `fixtures.exs FIXTURES.json`, then freeze with `ALTER DATABASE … SET default_transaction_read_only = on`, snapshot, and restore into a working copy.
6. On the working copy:
   1. `mix dd.export.replay --source S --out DIR`, then `mix dd.replay --dir DIR --source S`, for Wikipedia, then Wikidata;
   2. `mix dd.materialize --source S --all --resolve` for wikipedia, wikidata, johnson, bierce, wiktionary and wordnet;
   3. `mix dd.routing.verify --baseline FROZEN --projected`.
7. `operations.exs FIXTURES.json OPERATIONS.json` on the same copy.
