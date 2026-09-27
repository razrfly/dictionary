# Routing Stage 2 backfill

**Status:** implemented and rehearsed on isolated copies, 27 September 2026, for [routing issue #194](https://github.com/razrfly/dictionary/issues/194). **Not run on the development corpus.** A persistent run waits for the owner's decisions: the population, the reviewers, and the [corpus catch-up](corpus-catch-up.md).

`Routing.Backfill` (`mix dd.routing.backfill`) implements step 3 of ADR 0004 §8: decisions and durable pages in resumable batches, with checkpoints keyed by object identity and policy digest.

## What a run is bound to

A run is keyed by the SHA-256 of four inputs. It refuses inputs that do not agree with each other.

| Input | What it is | Bound by |
|---|---|---|
| Export | `policy-export.sql`'s read-only output for this database | its SHA-256 |
| Policy | `priv/routing/*.json` | its SHA-256, which the export's audit recorded |
| Population | `candidates.py`'s output for that export | its SHA-256; its own `inputs` must name the export's and policy's digests |
| Reviews (optional) | the reviewers' decisions, one per record | its SHA-256. The file names the population's digest, and each confirmation names the evidence fingerprint of the decision reviewed, from a run's manifest |

The same four digests are the same run, and it resumes from its checkpoint. A new review file makes a new run over the same population. Its writes are the same idempotent writes, so every page, path and decision carries over.

## Per record, in object-id order

1. **Is the evidence still what the export saw?** The record's evaluator input is read back from the database and compared with the export. Then every graph record the evaluation **depended on** is checked, not only the ones it matched: `Policy.classify/3` lists as `dependencies` each record it read — the entity's own, every class on a matched path, and every class it visited without finding a mapping — and each record it looked for and did not find. A record it read must still be at its **current** revision: the revision whose key is the record's content hash. That is not always the newest, because a payload that returns to an earlier one adds no revision. A record it did not find must still be absent. The result is a function of the input, the policy and exactly those records, so if they all still hold, a fresh evaluation reaches the same result. If anything has moved, the record is deferred with its reason, `input_changed` or `evidence_changed` (naming the records), and needs a fresh export, a fresh decision and a fresh review fingerprint. It is never classified from stale evidence.
2. **Classify.** `Policy.classify/3` runs, then `Classifications.record/1`. Unchanged evidence writes nothing, and a standing override is kept.
3. **Act on the population and the reviews:**

| Population disposition | Without a review | With a reviewer's `confirm` | With `defer` |
|---|---|---|---|
| allocation candidate | draft page, `awaiting_review` | the reviewer's override (once), the page, the uncontested candidate path allocated | `deferred_by_review` |
| collision review (proposed qualifier, or blocked) | draft page, `awaiting_review` | override, page, and the path **the reviewer names**, allocated. A collision is never qualified by import order. | `deferred_by_review` |
| classification or duplicate-identity review | `awaiting_review`, no page | override to the reviewer's family, page, and the reviewer's path | `deferred_by_review` |
| deferred or excluded | `not_addressed` | — | — |

A confirmation must name the fingerprint of the decision now current. A review made on other evidence is refused as stale, so it can neither outlive its evidence nor end a contradiction review.

A confirmation that cannot stand is `refused` for that record alone, and **leaves nothing it wrote**. What can be checked before writing is checked first: stale evidence, a collision confirmed without a path, a path someone else holds, a tombstone, an edition's address outside `/works`, a page that is not active or already has another address. The override, the page and the address are then written under one savepoint inside the batch's transaction. A refusal at any of those steps — the page's role, the ledger's own refusals, or something a concurrent writer changed after the checks — rolls back to the savepoint: the record's decisions, page, paths and ledger rows are what they were before the confirmation, its checkpoint says `refused` with the reason, and the batch goes on. The evaluator's own decision, recorded in step 2, stays: it is what a reviewer must see next. A reviewer may replace their own override.

An edition gets an edition page, whose address is in `/works`. Every other entity gets a subject page ([Stage 1, decision 1](../stage-1-foundation.md)).

4. **Checkpoint.** One `routing_backfill_items` row per record holds the disposition, its reason, and the decision, page and path ids.

A batch is one transaction: its writes and its checkpoint rows commit together. An interruption loses at most the batch in hand, and a resumed run starts after the last committed record. Every writer refuses per record without rolling the batch back ([Stage 1, decision 7](../stage-1-foundation.md)).

## Reviews

```json
{"population_sha256": "…",
 "reviews": [
  {"object_id": 1, "action": "confirm", "family": "people", "evidence_fingerprint": "…", "reviewer": "reviewer@example.com", "reason": "…"},
  {"object_id": 1846558, "action": "confirm", "family": "places", "path": "/places/daman-afghanistan", "evidence_fingerprint": "…", "reviewer": "…", "reason": "…"},
  {"object_id": 1846559, "action": "defer", "reviewer": "…", "reason": "…"}
]}
```

- **Where it comes from.** A run without reviews writes the manifest, which gives each record's current decision and its `evidence_fingerprint`. Reviewers decide from it.
- **Bound to the population.** The file names the population's digest. Each review names one record the population addresses, and each record gets at most one.
- **Paths.** A path is in the confirmed family. No two reviews approve the same path, and no review takes another record's proposed qualifier.
- **Reviewers.** Each is an account with the reviewer role. All are checked before anything is written.
- **Refused at load:** a file marked `"rehearsal": true`, which comes from a rule rather than from reviewers, except on a rehearsal copy.
- A duplicate-identity outcome of "the same subject" is a registry merge, which is outside the backfill: `defer` the record until it is merged.
- **No review may be written for someone.** The file records decisions people made.

## What it never does

- Publish. Pages stay `draft`, and candidate status grants no publication approval.
- Allocate without a named reviewer's confirmation, or qualify a collision by import order.
- Allocate a collection or choice page. It creates subject pages, and edition pages for editions.
- Touch a record outside the population. The rest of the corpus stays deferred, with the audit's dispositions.

## Checkpoint integrity

`routing_backfill_runs` and `routing_backfill_items` are append-only in the database. The one exception is a run's `finished_at`, which is set once. Both refuse `TRUNCATE` as the routing tables do.

## Limits

- **Dependencies, not the whole graph.** A run checks the records the evaluation read or looked for, which is everything its result depends on. It does not re-read the rest of the graph, and it does not re-evaluate from the database: a change it detects defers the record rather than classifying it afresh.
- **Races.** The ledger's locks turn a concurrent writer into a refusal, which the savepoint rolls back. A writer that bypassed those locks loses to an address's unique index instead; inside the batch's transaction the ledger cannot retry that, so it raises, the batch rolls back and the run stops. Running it again resumes it, and the taken address is then refused before anything is written. Two runs confirming paths in opposite orders can deadlock; PostgreSQL aborts one, with the same outcome.
- **Recovery.** The checkpoint is not part of the routing guard's digest. Losing it costs a re-run, and the re-run's writes are idempotent.
- **Which database.** The export's `database` attestation is not compared with the database being written, because a copy has another name. The content checks decide.

## Run

```bash
DD_NO_OBAN=1 mix dd.routing.backfill --snapshot EXPORT.jsonl --population candidates.json --manifest MANIFEST.json
```

Add `--reviews REVIEWS.json` once the reviewers have decided. The manifest is the candidate launch manifest: every population record with its disposition, decision, draft page, and its address, allocated or proposed.

## Rehearsal

On 27 September, at `495c118`, on copies of the development corpus as captured at 13:29 UTC (the scratch cluster; the source was only read). The copies were made from the capture itself, with no rehearsal fixture, and exported as the population was ([`candidates.json`](candidates.json), export SHA-256 `7524e9e3…`).

**Migration.** Checked against a reference made from the source's own schema and migration history. The copies carry two migrations from unmerged #210, which no empty reference could reproduce. The migration kept all 66 pre-existing tables unchanged and added exactly one migration, two tables and 67 schema rows.

**Runs on the first copy:**

| Run | Records | Result | Time |
|---|---:|---|---:|
| Without reviews | 170 | 129 `awaiting_review` (108 draft pages), 41 `not_addressed` | 2.3 s |
| The same again | 170 | nothing written: every id identical | 1.0 s |
| With rehearsal reviews, made from that run's manifest | 170 | 105 `allocated`, 24 `deferred_by_review`, 41 `not_addressed` | 2.5 s |
| The same again | 170 | nothing written: every id identical | 1.0 s |
| **The same reviews in other bytes**: a new run key over the same state | 170 | every record processed again. Every page, path, decision and ledger id unchanged; only the 170 new checkpoint rows added | 2.0 s |

**The rehearsal reviews are a rule, not approvals.** They confirm every allocation candidate's family, confirm every proposed qualifier as proposed, and defer the rest. Each names the fingerprint the manifest reported. Their only purpose is to exercise allocation at corpus scale on an isolated copy. The file is marked `"rehearsal": true`, which the backfill refuses anywhere else (`rehearsal/backfill.exs`).

**Crash and resume.**
- A second copy ran the same inputs. Its run without reviews matched the first copy's id for id.
- Its reviewed run was killed with `SIGKILL` after 72 of 170 checkpoint rows, unfinished, and then resumed.
- Afterwards all 170 objects matched the uninterrupted copy (`Backfill.state/1`): checkpoint rows and what they reference, the full decision history (275 decisions), the pages, their addresses, and every ledger row (210).
- Page ids were identical. The ids of paths, decisions, ledger rows and checkpoints differ only by the sequence values the killed batch consumed before it rolled back.

**Recovery of backfilled state.** The first copy, after all five runs, was snapshotted, restored into a new database, and `mix dd.routing.verify` matched it exactly: 275 decisions, 108 pages, 105 paths, 210 ledger rows, 510 checkpoint rows, 3 runs, and every path and page resolution.

**What the rehearsal and a review found.**
- The first corpus run refused both editions in the population, *Project Gutenberg #972* and the LEME 1755 transcription: it asked for a subject page, which `Pages.ensure/3` rightly refuses for an edition. The backfill now takes the page role the evaluator gives.
- An internal review found that reviews were not bound to the evidence reviewed, that pins were compared with the newest revision rather than the current one, and that an override could be written before a refusal. It also found gaps in the load checks and a checkpoint open to `TRUNCATE`, and that the repeat-run proof reused one run key. All are fixed in `495c118`. The regressions for binding, pin currency and refusal order fail without their fixes.
- The [independent audit](https://github.com/razrfly/dictionary/issues/194#issuecomment-5860062126) reproduced two defects that remained at `4b4a64b` and `0415e5b`. **P1:** only the matched evidence was checked for currency, so a class the walk visited without a match could change after the export — gaining an ancestor that maps elsewhere — and an old confirmation still allocated. **P2:** the override was written before the page and the ledger were asked, so a later refusal (a retired page, in the audit's probe) left a permanent reviewer override behind. Both are fixed under [#219](https://github.com/razrfly/dictionary/issues/219): every dependency is checked, and a confirmation's writes share one savepoint. The audit's two probes are regressions in `backfill_test.exs`, with seven more: newly arrived ancestry, a contradicting unmatched branch, a page of another role, a path taken and a canonical given by a concurrent writer after the checks, a subject's kind changing mid-batch, and a writer that bypassed the ledger's locks. Eight of the nine fail on the unfixed code; the ninth records a raise that was already right and now also proves the resume. The runs above predate these fixes; the [re-run on the corrected code](#re-run-on-the-corrected-code-219) follows.

**Before a persistent run:**
1. The owner decides on the corpus catch-up, the population and the reviewers.
2. The population is re-derived from a fresh export of the corpus as it then is.
3. The run: without reviews first. Its manifest is what the reviewers review.
4. Then the run with the reviewers' own file, and the candidate launch manifest from it.
