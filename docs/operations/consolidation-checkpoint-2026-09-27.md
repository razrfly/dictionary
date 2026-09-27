# Consolidation checkpoint and migration handoff, 2026-09-27

This branch, `codex/consolidation-2026-09-27`, is a **preservation and integration
checkpoint**. It exists so the dictionary can be moved to the external drive (#209)
with every piece of current code accounted for. It does **not** accept anything, merge
anything into `main`, or complete routing Stage 2 (#194). The coordinating plan is
[#193](https://github.com/razrfly/dictionary/issues/193#issuecomment-5856572444).

## What the branch contains

| Change set | Head included | Status |
|---|---|---|
| `main` (routing Stage 1 #205; curation slice 1 #206) | `c6bd882` | Accepted and merged |
| **#202**, curated opening Phase 1 (#156) | `7711e31` | **Accepted.** Independent readiness audit: A−, "ready for an authorized merge decision" ([#156](https://github.com/razrfly/dictionary/issues/156#issuecomment-5850893379)). Not merged: that decision is the owner's |
| **#210**, curation runtime stage A (#195) | `cb2e236` | **Not accepted.** CodeRabbit's nine threads are resolved; there is no independent audit. The author (the session that cut this checkpoint) re-verified it here, which is not independent acceptance |
| **#208**, Stage 2A recovery rehearsal (#194) | `2d495e8` | **Not accepted, in flight.** The PR head `0cd1114` (graded B, two CodeRabbit threads open) plus four commits another active session had committed but not pushed. Those commits (`aec0c6b`, `e67bbec`, `2d495e8`, and a merge of main) are the audit's section A repairs and part of section B. They have had no review. That session's uncommitted edits are **not** here; they stay in its worktree |

Each merge commit on this branch names its change set and status. The original
branches are untouched. The only migrations the branch adds over `main` are #210's two:
`20260927114948` and `20260927131023`.

## Checks run on this branch

Run by the session that cut the checkpoint, at `92d7265` (the last merge), on
isolated test partitions.

- `mix compile --warnings-as-errors` after each merge.
- **Combined migration path:**
  - main's schema (22 migrations) → the branch head (24);
  - roll back only the branch's two migrations, then forward again;
  - migrate from zero.

  The schema of the from-zero database equals the upgraded one, 5,490 lines of
  `pg_dump --schema-only`, byte for byte.
- `mix precommit`: 19 doctests, 2,453 tests, **0 failures**.
- #208's safety tests, run explicitly: 32 tests, 0 failures. This covers
  `RecoverySourceIdentityTest`, `RecoveryPreRoutingTest`, `MigrationCheckTest`,
  `RecoveryTest`, `SemanticReplayTest`, `WikidataDispatchTest` and
  `StateFingerprintTest`.
  - They fail with a partition name longer than about 8 characters. The test derives
    database names that pass PostgreSQL's 63-byte limit, and the code then refuses (it
    fails closed). The fix is test-only, in #208's code.

**Not run here:**
- independent audits of #210 and #208;
- the Stage 2 full-corpus replay, materialize and resolve;
- repeat-run and crash/resume proofs;
- live model inference;
- any restore of the development corpus.

## Incident: the shared development database was migrated

On 2026-09-27 at 13:11Z, a command in #210's session migrated `devils_dictionary_v2`
from `20260924222346` (pre-routing) to `20260927131023`, applying five migrations.

- The 23 tables they created are empty.
- Against the 10:49Z pre-routing snapshot, the schema has 0 lines removed or changed.
  The only additions are on those new tables.
- A rehearsal snapshot taken at 13:30Z copied this schema.

Details, and the rollback rehearsed on a test database:
[#194](https://github.com/razrfly/dictionary/issues/194#issuecomment-5856688338).
**Whether to roll it back before the move is the owner's decision.** The state
relocation must preserve depends on it.

## Migration handoff (#209)

**Code checkpoint:** this branch's head (the exact SHA is in the #209 handoff
comment), plus `main`.

**Preserve outside Git, and verify it after the move:**
- The one active session's uncommitted work, in the #208 worktree. It must commit and
  push first.
- Unpushed local branches from earlier work: the #143 and #144 phase branches, and
  `merge-154`.
- Two worktrees with local edits: a codex worktree's docs, and the
  `word-page-grouping` launch/dev config.
- Every worktree's ignored `data` symlink target.
- Database state:
  - the development corpus (`devils_dictionary_v2`, 14 GB);
  - the older corpora (`devils_dictionary_dev`, `…_bing135`, `…_74_verify`);
  - the two runtime evidence databases, `devils_dictionary_runtime_bench` (35
    attempts, 105 ledger entries) and `devils_dictionary_runtime_bench_b`;
  - the retained audit and test partitions. None is disposable by name alone.
- Already external, on the destination drive: the Stage 2A dumps, replay archives and
  scratch cluster (`/Volumes/LLM Models/dictionary-stage2a`), and the runtime's
  binaries, models and run state (`/Volumes/LLM Models/dictionary`).

**Protect:** the shared PostgreSQL 18.2 cluster on 5432 also serves other projects.
Relocate only dictionary databases, never the cluster's data directory, and touch
nothing else.

**Quiesce, in this order,** through each process's own terminal or launcher:
1. The active #208 session finishes its current rehearsal step, commits and pushes.
2. The main checkout's dev server (port 4007) and its public ngrok tunnel.
3. #202's preview server (port 4017).
4. Any other dictionary sessions.
5. The runtime service is already stopped.
6. Prove the window write-free: the sums of `n_tup_ins`, `n_tup_upd` and
   `n_tup_del` over `pg_stat_user_tables` are equal before the dump and after the
   copy is verified. Only then take the dumps.

**Back up and restore** with supported tools only, straight to the external drive;
the internal disk has about 4.6 GiB free.
1. Create a dedicated dictionary cluster on the external drive, from the same
   Postgres.app 18.2 binaries (so ICU collation versions match), on its own port. Do
   not use 5433: that is Stage 2's scratch cluster. Initialise it with UTF8,
   `en_US.UTF-8` and the ICU provider with the `en-US` locale. It needs the `citext`
   and `pg_trgm` extensions, and the `postgres` and `holden` roles
   (`pg_dumpall --globals-only`, reviewed).
2. `pg_dump -Fc` each dictionary database, with checksums recorded.
3. `pg_restore` into an explicitly named, empty database on the new cluster.
4. Do **not** use `mix dd.snapshot --restore` or other recovery tooling for this.
   Its source-identity protection is still under repair in #208.

**Verify each database, independently of the recovery tooling:**
- the schema-only dump is identical;
- `schema_migrations` is identical;
- per table, the row count **and** an ordered content digest are equal;
- every sequence's `last_value` and `is_called` are equal;
- owners, grants, extension versions, encoding and collation are equal.

Row counts alone are not enough.

**Cut over** by pointing clients at the new endpoint: `DD_DATABASE_PORT`, which the
branch adds, or the Repo configuration. Then:
- boot the application with Oban disabled first;
- run `mix precommit` from the external checkout, against an external test database;
- rebind the runtime with `mix dd.runtime service start --rebind`, deliberately. Its
  authority marker names the old cluster, so readiness refuses until then;
- confirm that nothing new was written to the internal disk.

**Roll back.** The source databases stay untouched on 5432 until the cutover is
verified and accepted. To roll back, point the clients back at 5432. Anything written
on the destination after cutover must first be dumped and reconciled: switching back
does not carry it over.

## Post-migration work (not done here)

- **#194 Stage 2:**
  - the recovery replay/materialize/resolve succeeding, and the full semantic delta;
  - cache/entity and legacy-label handling;
  - pending-relation equality;
  - repeat-run and crash/resume proofs;
  - the owner's population and reviewer decisions, classification and backfill;
  - the candidate launch manifest;
  - snapshot/restore of the backfilled state;
  - independent acceptance.
- **#195:**
  - an independent audit of #210;
  - a corrected instruction (lead and highlights distinct; satire still defines) and
    real, permitted benchmark evidence, re-pinned and re-benchmarked, **before any
    #197 panel work**.
- **#156:** the merge decision for #202.

Personalities, refresh, reader enablement and publication are outside this checkpoint.
