# Consolidation checkpoint, 2026-09-28 (#219 D5)

> **The move is done (7 October 2026, [#211](https://github.com/razrfly/dictionary/issues/211)).** The dictionary runs from the external drive on its own cluster, `system_identifier` 7693849764459364596 on port 5434 ([`211-cutover.md`](211-cutover.md)). The dictionary databases this record lists on 5432 were dropped by exact name in the reclaim, except `devils_dictionary_ex212`. The 5432 cluster keeps `devils_dictionary_ex212` and other projects' databases. This file is kept as the record of its date.

This re-cuts the [27 September checkpoint](consolidation-checkpoint-2026-09-27.md) against the new `main`, for [#211](https://github.com/razrfly/dictionary/issues/211)'s entry. That record's integration branch (`codex/consolidation-2026-09-27`) is superseded: everything it integrated is now on `main`. Its migration procedure still applies, with the changes below.

## `main`

**`04f97bc`** for the code; this document and the demonstration record merged after it and change nothing else. No integration branch is designated: `main` is the whole accepted state. Local `main` is to equal `origin/main`, and the #219 closing comment records that it does.

Merged under [#219](https://github.com/razrfly/dictionary/issues/219), in order and with merge commits, branches kept:

| PR | Merge | What | Accepted by |
|---|---|---|---|
| [#208](https://github.com/razrfly/dictionary/pull/208) | `484d21e` | Stage 2 recovery repair; A4's URL target fix | independent re-review A6: **A** |
| [#216](https://github.com/razrfly/dictionary/pull/216) | `903f82b` | the resumable backfill; A1 dependencies, A2 atomic confirmation | A6: A−, pending the corrected-code re-run; that re-run is now recorded |
| [#220](https://github.com/razrfly/dictionary/pull/220) | `64f12cd` | `local_model_configs_shape` repair (schema reconciliation, option i) | the #210 audit; CodeRabbit answered |
| [#202](https://github.com/razrfly/dictionary/pull/202) | `e1d60b0` | curated opening, Phase 1 | readiness audit A−; the owner's merge decision, 28 September |
| [#225](https://github.com/razrfly/dictionary/pull/225) | `04f97bc` | On replaces Define; subjects at their own addresses | independent review (five lenses, each verified) |

#210 had merged before, as `d31d212`.

**Validated after each merge**, on a private `MIX_TEST_PARTITION`:
- `compile --warnings-as-errors`;
- `mix precommit`: 2,372 → 2,402 → 2,402 → 2,492 → 2,540 tests, 19 doctests, 0 failures;
- the migration path. A schema-only copy of `devils_dictionary_v2` (head `20260927131023`, 24 migrations) on the scratch cluster applies exactly `20260927200717`, then `20260927220937`. The result equals a database migrated from zero (26 migrations), apart from whitespace in function bodies.

## What `main` expects after the move

The working database is at `20260927131023`. `main` adds two migrations, applied **after** preservation passes:

1. `20260927200717`: `routing_backfill_runs`, `routing_backfill_items` (#216).
2. `20260927220937`: re-states `local_model_configs_shape` as merged. The 13:11Z incident left the early draft on v2. Check `SELECT count(*) FROM local_model_configs` first (0 on 28 September). The table is append-only, so a row the repaired constraint rejects is investigated, not rewritten.

## Changes to the 27 September procedure

- **Recovery tooling is repaired and merged (#208).** The move still uses `pg_dump`/`pg_restore` and the independent verification the procedure lists. `mix dd.routing.verify` may be run in addition, as a second check, not instead.
- **The incident is decided:** option (i). v2 keeps its migrations, and #220 repairs the one drifted constraint after the move. No rollback.
- **Quiesce:** nothing is left in flight from #208. **Still running on 28 September**, and the owner's to stop from their own terminals:
  - the 4007 dev server (22 connections to v2);
  - its ngrok tunnel;
  - the 4017 preview.

  Also this session's demo servers on 4219 and 4220 (scratch cluster only), which it stops itself.

## Preserved work outside `main`

- **Open PRs:**
  - #212's exemplar builds, [#218](https://github.com/razrfly/dictionary/pull/218) and [#223](https://github.com/razrfly/dictionary/pull/223), their own session's;
  - #210's should-fix items, [#221](https://github.com/razrfly/dictionary/issues/221) (an issue).
- **Unmerged branches:**
  - `claude/143-spotify-music-6bb8a8`, 1 commit;
  - `claude/144-kit-phase3`, 5 commits;
  - `codex/consolidation-2026-09-27`, superseded; its one unique commit is this file's predecessor.
- **Evidence (local, ignored):** `data/audits/2026-09-28-219/`. It holds:
  - A5, A5-final and A6 with its delta review;
  - the merge validations;
  - the demonstration copy's build;
  - the reader review.

  The dumps `219a-backfilled.dump` and `219d-backfilled.dump` are under `/Volumes/LLM Models/dictionary-stage2a/stage2r/dumps/`, beside `b0`, `c1`, `c1-899`, `bfa`, `v2-source` and `w1-prefix`.

## Worktrees (D2)

The 27 September reclaim archived nineteen idle sessions. Their directories are the owner's to remove. Every worktree below was checked on 28 September for:
- no process with it as working directory (`lsof -d cwd`);
- nothing ignored but build caches, `.env`, `data` and `tmp`;
- its branch merged, or holding only local merge commits of merged work.

| Worktree | Branch | State | Disposition |
|---|---|---|---|
| `issue-219-backfill-a` | `claude/219-backfill-acceptance` (`0415e5b`) | merged; no process; `.env` byte-identical to the main checkout's | owner removes |
| `wf_dd7e7ea3-b57-1/2/3`, `wf_6372bf64-852-1/2` | `a5-rehearsal`, `a6-review`, detached, `a5-final`, `a6-delta` | local merge commits of #208 and #216, now merged; evidence already in `data/audits/2026-09-28-219/`; no process | owner removes; then `git branch -D` those four branches |
| `source-listing-ui-ef5442` | `claude/219-on-reader` | this session's | removed after this session ends |
| `dictionary-issue-194-stage-1-218d99` | local `codex/routing-stage-2b-backfill` at `0415e5b` (behind origin) | #216 merged; **a process still holds it** | left to its session; remove after it ends |
| `stage-2-routing-audit-372bbd` | `claude/210-shape-repair` | #220 merged; a process holds it | left to its session |
| `dictionary-curated-opening-phase1-f69daa` | #202's branch | merged; two processes hold it | left to its session |
| `172-final-sweep`, `212-exemplar-items-b549d7`, `curation-persistence-196`, `exemplar-layer-build-2-32d57f`, `word-level-tier-shelves-720f8b` | various | a live process each | left to their sessions |
| `143-spotify-music-6bb8a8`, `144-kit-de9e9d` | unmerged | no process | kept: unmerged work |
| `agent-af1d237d1510eb466` | `claude/158-build1` | locked | left |
| the two `~/.codex` worktrees | detached | codex's | left |

`.claude/settings.local.json` exists in several worktrees. It is per-worktree tool configuration, not evidence. Where a worktree is removed, it goes with it unless the owner wants it kept. No credential is recorded here.

## Databases (D3)

**An inventory, not an authorization: nothing here is dropped.** A drop needs the owner's authorization naming the exact database and server. Two clusters:
- **5432**, `system_identifier` 7607810074859095446, PostgreSQL 18.2, shared with other projects. It holds 123 dictionary databases, 29.4 GB.
- **5433**, `system_identifier` 7690164109148229279, the scratch cluster on `/Volumes/LLM Models/dictionary-stage2a/pgdata`. It holds 35 dictionary databases, 310.5 GB (`pg_database_size`, as are the rows below, which add up to it).

| Server | Database | GB | Purpose, and what depends on it | Proposed disposition |
|---|---|---:|---|---|
| 5432 | `devils_dictionary_v2` | 14.7 | the working corpus; 4007 is connected | **keep**; #211 moves it |
| 5432 | `devils_dictionary_dev` | 3.4 | Gate 0 baseline named in `config/dev.exs`; ADR 0001 and Gate 0 evidence | keep until the owner retires Gate 0's baseline |
| 5432 | `devils_dictionary_74_verify` | 4.5 | #74 rebuild verification; cited by `docs/rebuild/` as past evidence | drop after the move, if authorized |
| 5432 | `devils_dictionary_bing135` | 4.5 | #135 Bing News trial copy | drop after the move, if authorized |
| 5432 | `devils_dictionary_runtime_bench`, `_b` | 0.0 | #210 runtime evidence; the service is bound to `runtime_bench` | **keep**; rebind after the move |
| 5432 | `devils_dictionary_ex181`, `_ex181b2` | 0.0 | #181 examples work, merged | drop, if authorized |
| 5432 | `devils_dictionary_ex212` | 0.0 | #212 exemplar work, PRs open | keep until #212 lands |
| 5432 | `devils_dictionary_test` and 113 more `devils_dictionary_test*` databases, 19 of them this issue's `_219*` partitions | ≤ 0.1 each | test databases, rebuilt by `mix test` | drop as a batch when no session uses them, if authorized |
| 5433 | `stage2r_c1` | 10.0 | **frozen** caught-up capture; the source of every #219 copy | **keep** |
| 5433 | `stage2r_caughtup` | 13.3 | the caught-up baseline | **keep** |
| 5433 | `stage2r_bfa2` | 10.0 | verified restore of the first backfill rehearsal; retained audit evidence | **keep** |
| 5433 | `stage2r_219final` | 10.0 | **the demonstration copy** for #219 and D5 | keep until CP4 (#224) starts |
| 5433 | `stage2r_219d`, `_219e`, `_219f` | 29.9 | A5-final: backfilled, crash/resume, exact restore; `219d-backfilled.dump` keeps the state | drop after #219 closes, if authorized |
| 5433 | `stage2r_219a`, `_219b`, `_219c`, `_219demo` | 39.9 | the first A5 run (superseded) and the earlier demo copy; `219a-backfilled.dump` kept | drop, if authorized |
| 5433 | `stage2r_219ref`, `_219ref2`, `_219v2schema`, `_219v2m`, `_219freshrt`, `stage2r_bfref`, `stage2r_reference` | 0.1 | schema-only references for migration checks | drop, if authorized |
| 5433 | `stage2r_base` | 10.0 | B0, the frozen baseline of the recovery repair | keep until #211 completes |
| 5433 | `stage2r_w1`, `_w1prefix_frozen`, `_p1`, `_p2`, `_p3`, `_from2a`, `_source`, `_bfa`, `_bfb` | 103.6 | recovery-repair and first-backfill working copies; their states are in the dumps and reports | drop after #211, if authorized |
| 5433 | `stage2r_c1_899`, `_p1_899`, `_p2_899`, `_p3_899` | 50.6 | runs at `899aaaf`, superseded and kept as evidence | drop after #211, if authorized |
| 5433 | `stage2a_baseline`, `_working`, `_ops` | 33.0 | the Stage 2A rehearsal ([record](../routing/stage-2/recovery-rehearsal.md)) | keep until #211 completes |

The 5432 cluster also holds other projects' databases. They are out of scope and untouched.

## Demonstration from `main` (D5)

The journey ran at **`04f97bc`** on `stage2r_219final`. That copy was restored from `c1.dump` with `mix dd.snapshot --restore`, verified exact against `stage2r_c1`, and migrated. It was then backfilled with regenerated **rehearsal reviews** (105 allocated, 24 deferred, 41 not addressed; manifest records identical to A5-final's) and given the Mars fixtures by `on_demo.exs`. See [`docs/routing/on-demo/`](../routing/on-demo/README.md).
