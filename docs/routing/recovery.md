# Routing recovery procedure

**Status:** supported procedure, 27 September 2026, for [routing issue #194](https://github.com/razrfly/dictionary/issues/194). It has been exercised end to end by `test/devils_dictionary/routing/recovery_test.exs` against isolated, disposable databases. It has **not** been run against the development corpus (`devils_dictionary_v2`), which this work did not touch. The first real exercise must happen before Stage 2 writes any persistent backfill.

## What must survive, and why a rebuild cannot provide it

Registry object ids exist only in the database. Pages, classification decisions and overrides, page revisions and memberships, canonical pointers, historical path reservations, and the route ledger all reference those ids or each other.

`mix dd.rebuild` re-derives the corpus from archived inputs. Run after `mix dd.reset`, it mints new ids for every object. A rebuilt database therefore reproduces *content* (which is what `mix dd.verify.rebuild` compares) but not *identity*. ADR 0004 §8 is explicit: "Replaying source data into newly numbered objects does not satisfy restore acceptance."

So routing state is recovered, not regenerated:

- **Restore** the whole database: the registry together with the routing state that references it.
- **Re-project** it from its own source records. This is idempotent, and binds to the ids that are already there.

## Guards on destructive tasks

`mix dd.reset`, `mix dd.snapshot --restore` (over a target), `mix dd.rebuild` (except with `--dry-run`) and `mix ecto.drop` (so `mix ecto.reset` too) first ask `Routing.Recovery.guard/3` whether the target database holds durable routing state. If it does, they refuse unless they are given a snapshot that covers it: `--routing-snapshot PATH`, or `DD_ROUTING_SNAPSHOT=PATH` for `ecto.drop`, whose `mix.exs` alias runs `mix dd.routing.guard drop` first.

The guard reads the database name as Ecto does, so a production `url:` configuration is checked too. A configuration that names no database is refused.

A covering snapshot has a `PATH.routing.json` sidecar that records:

- **the dump itself**: its size and SHA-256, so a truncated or replaced file is refused even when `pg_restore --list` can still read it;
- **the same database**, by name;
- **a digest of every routing row**, whole, equal to the database's digest now.

The dump must also contain every routing table (checked with `pg_restore --list`).

Rolling the routing migration back would drop every routing table, so it refuses while any routing row exists (`mix ecto.rollback` raises). Emptying the tables first is a deliberate act: it needs `dictionary.allow_routing_truncate` set in the transaction that does it.

`mix dd.snapshot` writes that sidecar, and makes it exact. A repeatable-read transaction exports its snapshot (`pg_export_snapshot()`), computes the digest by streaming each routing table through a cursor, and keeps the snapshot open while `pg_dump --snapshot` dumps under it. The digest therefore describes exactly the rows in the dump:

- A write still in flight during the dump is in neither. Once it commits, the digests differ and the guard refuses.
- Any committed routing change counts, including one that adds no id, such as a change of publication state.

The dump is written to `PATH.partial` and renamed only when complete. Any older sidecar is deleted first, so a failed dump never leaves a sidecar that seems to vouch for it. A dump without the sidecar does not count.

These guards stop accidents. They do not stop an operator: naming a snapshot is a deliberate acknowledgement. The routing tables also refuse `TRUNCATE`, including one cascading from `objects`, unless a transaction sets `dictionary.allow_routing_truncate`. Only the test suite's reset does that. Production should also deny the application's database role TRUNCATE and trigger control.

## Procedure

Every step except the first writes only to a new, separate database.

A restored copy carries the source's queued and scheduled jobs. Tasks that start the application would otherwise run them against the copy, and the quotation verifier makes outbound requests. `mix dd.routing.verify` starts only the Repo. For every other command on the copy, set `DD_NO_OBAN=1`, which starts Oban with no queues and no plugins. Never restore over the live database: the guard refuses without a covering snapshot, and you would lose whatever the snapshot does not hold.

1. **Quiesce, then snapshot the source.** Step 3 compares the copy with the **live** source, so the source must take no writes from here until step 3 is done. Stop the application, its Oban node and any running tasks. The snapshot itself is read-only, and writes the dump and its `.routing.json` digest.

   ```bash
   mix dd.snapshot --out ~/Backups/dictionary-routing.dump
   ```

2. **Restore into an isolated database.** The name must begin with `devils_dictionary`, and `DD_DATABASE` must name it.

   ```bash
   DD_DATABASE=devils_dictionary_restore mix dd.snapshot --restore ~/Backups/dictionary-routing.dump --database devils_dictionary_restore
   ```

   Do **not** run `mix ecto.migrate` on the copy before step 3. A copy migrated past its source is a different schema, and step 3 reports the difference. Migrate after switching over, like any deploy.

3. **Verify exact identity.** This compares every column of every table: registry identities, references such as an edition's work or a variant's canonical lexeme, and every routing row, all by exact id. Only Oban's queue tables are left out. It also compares:

   - the schema: owners; column types, collations, nullability and defaults; constraints and indexes, including whether they are valid; triggers, including whether they fire; functions, views and rules; sequence parameters; row security and policies; object, schema and default privileges; extension versions;
   - every sequence's own state: its last value and whether it has been used (`is_called`), which together fix the next id it hands out. This includes sequences never used, whose `pg_sequences.last_value` is null;
   - what every stored path and page id resolves to.

   Counts alone are not accepted. It is read-only on both databases, and exits non-zero on any difference.

   `mix dd.snapshot --restore` restores neither ownership nor privileges (`--no-owner --no-privileges`). Every restored object belongs to the role that ran the restore, and carries its type's default privileges.
   - **Restore as the role that owns the source.** An owner implicitly holds TRUNCATE and may disable triggers, so ownership matters, and it is compared by role name.
   - **Then apply the source's grants to the copy.** Privileges are compared as granted, not as stored. An ACL that was reset to its default equals one that was never set, and the owner appears in it only as `owner`. So once the copy has the same owner and the same grants, it matches.
   - Where the source grants nothing beyond the defaults, as in development, there is nothing to apply.

   The report lists the schema and sequence rows that differ.

   ```bash
   DD_DATABASE=devils_dictionary_restore mix dd.routing.verify --baseline devils_dictionary_v2
   ```

4. **Re-project the copy from its own records, in any provider order.** `mix dd.materialize --all` re-projects every implemented source from the source records the copy holds. It also asserts that nothing derived changed (scorecard M2). Repeat it for each source, in whatever order:

   ```bash
   DD_NO_OBAN=1 DD_DATABASE=devils_dictionary_restore mix dd.materialize --source wikidata --all
   ```

   To exercise the replay path as well, replay the API sources **only from an archive exported from the copy itself**. The pinned `priv/replay` archive may be older than the snapshot, and would re-project different records:

   ```bash
   DD_NO_OBAN=1 DD_DATABASE=devils_dictionary_restore mix dd.export.replay --out /tmp/restore-replay --quiet
   ```

   ```bash
   DD_NO_OBAN=1 DD_DATABASE=devils_dictionary_restore mix dd.replay --dir /tmp/restore-replay --source wikidata
   ```

   Then verify again. After re-projection the comparison leaves out the projection's own bookkeeping: its new `import_runs`, and the `updated_at`, `materialized_at` and `last_seen_run_id` stamps it rewrites. `RecoveryTest` observed each of these change, and nothing else. Sequences then need only not have fallen behind their tables, because upserts may consume ids without writing rows:

   ```bash
   DD_DATABASE=devils_dictionary_restore mix dd.routing.verify --baseline devils_dictionary_v2 --projected
   ```

5. **Check operations.** Resolve a few known paths, and run one ledger operation on a scratch page in the restored copy. The recovery test does this: a move, a rollback of an operation recorded before the snapshot, and a new allocation whose ids follow on from the restored sequences.

6. **Switch over.** Pointing the application at the verified copy is an operator decision (`DD_DATABASE`, or configuration). This procedure never changes it.

## What the test proves

`RecoveryTest` builds its registry through the real projection. It inserts Wikipedia's and Wikidata's fixture records for cat, dog and oyster and materializes them, Wikipedia first. On top of that it writes:

- a routing history that reaches every routing table and every operation: allocate, move, merge, split, retire, restore and rollback. It includes an evaluator decision with a human override, subject and On pages, and revisions with typed membership;
- registry references outside the routing tables: an edition of a work, and a variant spelling with its canonical lexeme.

The test then runs the procedure's steps:

- the snapshot goes through `Routing.Recovery.snapshot!/2` (the code behind `mix dd.snapshot`), and the restore through `DevilsDictionary.Snapshot`, into a database created for the test and dropped after it;
- `mix dd.routing.verify` passes, and every section is compared row for row, along with every resolution and every sequence;
- moving a sequence that was never used, to any value with or without `is_called`, is a difference in exactly `sequences`. So is changing only a used sequence's `is_called`. Restoring either state verifies exactly again;
- the copy exports its own replay archive, then re-projects with `mix dd.replay` and `mix dd.materialize --all`, **Wikidata before Wikipedia**. The test asserts that each source's three records were really replayed and re-materialized, in that order, and then compares everything again in projected mode;
- on the restored copy it resolves known paths, moves a page, rolls back a move recorded before the snapshot, and allocates a new page whose id follows on;
- the comparison is shown to be non-vacuous:
  - after those writes, verification reports differences in `pages` and `route_changes`;
  - changing only an edition's work and a variant's canonical lexeme differs in exactly `edition_details` and `lexemes`;
  - disabling the ledger's guard trigger, or granting a privilege, differs in exactly the schema, while revoking the grant again, which leaves an explicit default ACL, does not;
- the source database was only read: its manifest is unchanged at the end.

A second test covers the guards:

- `dd.reset`, `dd.snapshot --restore`, `dd.rebuild` and `dd.routing.guard` refuse a database holding routing state without a covering snapshot, and accept a covering one;
- the guard reads a `url:` configuration, and refuses one that names no database. Under a `url:` configuration, verification still reads the database it is asked to;
- rolling the routing migration back refuses, and the tables are still there;
- the guard refuses:
  - a snapshot of another database with the same rows;
  - a plain dump without a digest, and a missing file;
  - a truncated dump, and a dump replaced by another;
  - a snapshot taken before a publication change;
  - a snapshot taken while a routing write was in flight, once that write commits;
- the real `mix ecto.drop`, alias and all, refuses the disposable copy, then drops it once `DD_ROUTING_SNAPSHOT` names a covering snapshot.

## Limits

- **Scale.** The manifest streams through a server-side cursor in constant memory. Its running time against the full corpus (about 3.7 million objects and 3.9 million assertion revisions) has not been measured. That is Stage 2's first gate.
- **Bodies are compared by hash.** `text`, `json`, `jsonb` and `bytea` columns are compared by MD5, which catches accidents, not an adversary.
- **Ownership and privileges are compared, but not restored.** Step 3 says how to make them match.
- **Schema definitions** are compared as Postgres deparses them. There is one exception: an `IN` list written `x = ANY ((ARRAY['a'::varchar, …])::text[])` is compared in the form a restored server re-parses it to (`ARRAY[('a'::varchar)::text, …]`), because it is the same condition. Nothing else is rewritten.
- **The routing migration was amended in place** while its branch was unmerged. A database migrated at an earlier head of the branch has the same version number and different constraints. The schema section reports that. Such a database can hold no real routing state yet, because nothing writes it before Stage 2, so the fix is to roll back that one migration and migrate again. The rollback refuses if any routing row exists.
- **The guards are conservative, not transactional.** Any routing change since the snapshot refuses, even one the operator would not care about. A write committed between the guard's check and the drop is still lost, which is why step 1 quiesces.
- **"Human" is an actor check.** The ledger and the database require a `user` actor for human-only operations. Any code holding the application's database role could still write rows naming a `user` actor. Separate database roles for the application and for reviewers would close that; Stage 1 does not add them.
