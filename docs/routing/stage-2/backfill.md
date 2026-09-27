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
| Reviews (optional) | the reviewers' decisions, one per record | its SHA-256 |

The same four digests are the same run, and it resumes from its checkpoint. A new review file makes a new run over the same population. Its writes are the same idempotent writes, so every page, path and decision carries over.

## Per record, in object-id order

1. **Is the evidence still what the export saw?** The record's evaluator input is read back from the database and compared with the export. Every revision the evaluator pins must still be its record's latest. If either has moved, the record is deferred with its reason: `input_changed` or `evidence_changed`. It is never classified from stale evidence.
2. **Classify.** `Policy.classify/3` runs, then `Classifications.record/1`. Unchanged evidence writes nothing, and a standing override is kept.
3. **Act on the population and the reviews:**

| Population disposition | Without a review | With a reviewer's `confirm` | With `defer` |
|---|---|---|---|
| allocation candidate | draft page, `awaiting_review` | the reviewer's override (once), the page, the uncontested candidate path allocated | `deferred_by_review` |
| collision review (proposed qualifier, or blocked) | draft page, `awaiting_review` | override, page, and the path **the reviewer names**, allocated. A collision is never qualified by import order. | `deferred_by_review` |
| classification or duplicate-identity review | `awaiting_review`, no page | override to the reviewer's family, page, and the reviewer's path | `deferred_by_review` |
| deferred or excluded | `not_addressed` | — | — |

A confirmation that cannot stand is `refused` for that record alone. Examples: a path outside the confirmed family, a collision confirmed without a path, a path someone else holds, a tombstone.

An edition gets an edition page, whose address is in `/works`. Every other entity gets a subject page ([Stage 1, decision 1](../stage-1-foundation.md)).

4. **Checkpoint.** One `routing_backfill_items` row per record holds the disposition, its reason, and the decision, page and path ids.

A batch is one transaction: its writes and its checkpoint rows commit together. An interruption loses at most the batch in hand, and a resumed run starts after the last committed record. Every writer refuses per record without rolling the batch back ([Stage 1, decision 7](../stage-1-foundation.md)).

## Reviews

```json
{"reviews": [
  {"object_id": 1, "action": "confirm", "family": "people", "reviewer": "reviewer@example.com", "reason": "…"},
  {"object_id": 1846558, "action": "confirm", "family": "places", "path": "/places/daman-afghanistan", "reviewer": "…", "reason": "…"},
  {"object_id": 1846559, "action": "defer", "reviewer": "…", "reason": "…"}
]}
```

- Each review names one population record, and each record gets at most one.
- The reviewer is an account with the reviewer role. The run refuses, before writing anything, an account that does not exist or lacks the role.
- A duplicate-identity outcome of "the same subject" is a registry merge, which is outside the backfill: `defer` the record until it is merged.
- **No review may be written for someone.** The file records decisions people made.

## What it never does

- Publish. Pages stay `draft`, and candidate status grants no publication approval.
- Allocate without a named reviewer's confirmation, or qualify a collision by import order.
- Allocate a collection or choice page. It creates subject pages only.
- Touch a record outside the population. The rest of the corpus stays deferred, with the audit's dispositions.

## Checkpoint integrity

`routing_backfill_runs` and `routing_backfill_items` are append-only in the database. The one exception is a run's `finished_at`, which is set once.

## Run

```bash
DD_NO_OBAN=1 mix dd.routing.backfill --snapshot EXPORT.jsonl --population candidates.json --manifest MANIFEST.json
```

Add `--reviews REVIEWS.json` once the reviewers have decided. The manifest is the candidate launch manifest: every population record with its disposition, decision, draft page, and its address, allocated or proposed.

## Rehearsal

On 27 September, at `576f954`, on copies of the development corpus as captured at 13:29 UTC (the scratch cluster; the source was only read). The copies were made from the capture itself, with no rehearsal fixture, and exported as the population was ([`candidates.json`](candidates.json), export SHA-256 `7524e9e3…`).

**Migration.** Checked against a reference made from the source's own schema and migration history. The copies carry two migrations from unmerged #210, which no empty reference could reproduce. The migration kept all 66 pre-existing tables unchanged and added exactly one migration, two tables and 65 schema rows.

**Runs:**

| Run | Records | Dispositions | Time |
|---|---:|---|---:|
| Without reviews | 170 | 129 `awaiting_review` (108 draft pages), 41 `not_addressed` | 2.1 s |
| The same again | 170 | nothing written: every id identical | 0.9 s |
| With rehearsal reviews | 170 | 105 `allocated`, 24 `deferred_by_review`, 41 `not_addressed` | 2.6 s |
| The same again | 170 | nothing written: every id identical | 0.9 s |

**The rehearsal reviews are a rule, not approvals.** They confirm every allocation candidate's family, confirm every proposed qualifier as proposed, and defer the rest. Their only purpose is to exercise allocation at corpus scale on an isolated copy. Every reason says so, and the rule is never to be used on the development corpus (`rehearsal/backfill.exs`).

**Crash and resume.**
- A second copy ran the same inputs. Its run without reviews matched the first copy's id for id.
- Its reviewed run was killed with `SIGKILL` after 42 of 170 checkpoint rows, unfinished, and then resumed.
- Afterwards all 170 objects matched the uninterrupted copy (`Backfill.state/1`): decision, page, addresses and disposition.
- Page ids were identical. The ids of paths, decisions, ledger rows and checkpoints differ only by the sequence values the killed batch consumed before it rolled back.

**Recovery of backfilled state.** The first copy was snapshotted, restored into a new database, and `mix dd.routing.verify` matched it exactly: 275 decisions, 108 pages, 105 paths, 210 ledger rows, 340 checkpoint rows, and every path and page resolution.

**A defect it found.** The first corpus run refused both editions in the population, *Project Gutenberg #972* and the LEME 1755 transcription: it asked for a subject page, which `Pages.ensure/3` rightly refuses for an edition. The backfill now takes the page role the evaluator gives (`576f954`). A regression covers it.

**Before a persistent run:**
1. The owner decides on the corpus catch-up, the population and the reviewers.
2. The population is re-derived from a fresh export of the corpus as it then is.
3. The run: without reviews first, then with the reviewers' own file.
4. The candidate launch manifest comes from that run.
