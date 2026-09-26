# Routing recovery procedure

**Status:** supported procedure, 27 September 2026, for [routing issue #194](https://github.com/razrfly/dictionary/issues/194). It has been exercised end to end by `test/devils_dictionary/routing/recovery_test.exs` against isolated, disposable databases. It has **not** been run against the development corpus (`devils_dictionary_v2`), which this work did not touch. The first real exercise must happen before Stage 2 writes any persistent backfill.

## What must survive, and why a rebuild cannot provide it

Registry object ids exist only in the database. Pages, classification decisions and overrides, page revisions and memberships, canonical pointers, historical path reservations, and the route ledger all reference those ids or each other.

`mix dd.rebuild` re-derives the corpus from archived inputs. Run after `mix dd.reset`, it mints new ids for every object. A rebuilt database therefore reproduces *content* (which is what `mix dd.verify.rebuild` compares) but not *identity*. ADR 0004 §8 is explicit: "Replaying source data into newly numbered objects does not satisfy restore acceptance."

So routing state is recovered, not regenerated:

- **Restore** the whole database: the registry together with the routing state that references it.
- **Re-project** it from its own source records. This is idempotent, and binds to the ids that are already there.

## Guards on destructive tasks

`mix dd.reset`, `mix dd.snapshot --restore` (over a target) and `mix dd.rebuild` (except with `--dry-run`) first ask `Routing.Recovery.guard/3` whether the target database holds durable routing state. If it does, they refuse unless `--routing-snapshot PATH` names a snapshot that:

- contains every routing table (checked with `pg_restore --list`), and
- has a `PATH.routing.json` sidecar whose routing high-water marks equal the database's current ones. The marks are the maximum id of each routing table and the last page update. Equal marks mean no routing write has happened since the snapshot was taken.

`mix dd.snapshot` writes that sidecar. It reads the marks **before** the dump starts, so a routing write that races the dump makes the snapshot look older, never newer, and the guard errs toward refusing. A snapshot without the sidecar does not count.

These guards stop accidents. They do not stop an operator: `--routing-snapshot` is a deliberate acknowledgement. The routing tables also refuse `TRUNCATE`, including one cascading from `objects`, unless a transaction sets `dictionary.allow_routing_truncate`. Only the test suite's reset does that. Production should also deny the application's database role TRUNCATE and trigger control.

## Procedure

Every step except the first writes only to a new, separate database.

A restored copy carries the source's queued and scheduled jobs. Tasks that start the application would otherwise run them against the copy, and the quotation verifier makes outbound requests. `mix dd.routing.verify` starts only the Repo. For every other command on the copy, set `DD_NO_OBAN=1`, which starts Oban with no queues and no plugins. Never restore over the live database: the guard refuses without a covering snapshot, and you would lose whatever the snapshot does not hold.

1. **Snapshot the source.** This is read-only, and writes the dump and its `.routing.json` marks. Quiesce routing writes first if you can.

   ```bash
   mix dd.snapshot --out ~/Backups/dictionary-routing.dump
   ```

2. **Restore into an isolated database.** The name must begin with `devils_dictionary`, and `DD_DATABASE` must name it.

   ```bash
   DD_DATABASE=devils_dictionary_restore mix dd.snapshot --restore ~/Backups/dictionary-routing.dump --database devils_dictionary_restore
   ```

   ```bash
   DD_DATABASE=devils_dictionary_restore mix ecto.migrate
   ```

3. **Verify exact identity.** This compares every registry identity and every routing row by exact id and reference (`Routing.Recovery.manifest/1`), the sequences that hand out the next ids, and what every stored path and page id resolves to. Counts alone are not accepted. It is read-only on both databases, and exits non-zero on any difference.

   ```bash
   DD_DATABASE=devils_dictionary_restore mix dd.routing.verify --baseline devils_dictionary_v2
   ```

4. **Re-project from source records, in any provider order.** Replay archives (for the API sources) and re-materialize every implemented source. `--all` also asserts that nothing derived changed (scorecard M2).

   ```bash
   DD_NO_OBAN=1 DD_DATABASE=devils_dictionary_restore mix dd.replay --source wikidata
   ```

   ```bash
   DD_NO_OBAN=1 DD_DATABASE=devils_dictionary_restore mix dd.materialize --source wikidata --all
   ```

   Repeat for each source, in whatever order. Then verify again. After re-projection, sequences need only not have fallen behind their tables, because upserts may consume ids without writing rows:

   ```bash
   DD_DATABASE=devils_dictionary_restore mix dd.routing.verify --baseline devils_dictionary_v2 --projected
   ```

5. **Check operations.** Resolve a few known paths, and run one ledger operation on a scratch page in the restored copy. The recovery test does this: a move, a rollback of an operation recorded before the snapshot, and a new allocation whose ids follow on from the restored sequences.

6. **Switch over.** Pointing the application at the verified copy is an operator decision (`DD_DATABASE`, or configuration). This procedure never changes it.

## What the test proves

`RecoveryTest` builds its registry through the real projection. It inserts Wikipedia's and Wikidata's fixture records for cat, dog and oyster and materializes them, Wikipedia first. On top of that it writes a routing history that reaches every routing table and every operation: allocate, move, merge, split, retire, restore and rollback. That history includes an evaluator decision with a human override, subject and On pages, and revisions with typed membership. The test then runs the procedure's steps:

- the dump and restore go through `DevilsDictionary.Snapshot` (the code behind `mix dd.snapshot`) into a database created for the test and dropped after it;
- every manifest section is compared row for row, along with every resolution and every sequence;
- the copy is re-projected with `mix dd.replay` and `mix dd.materialize --all`, **Wikidata before Wikipedia**. The test asserts that each source's three records were really replayed and re-materialized, in that order, and then compares everything exactly again;
- on the restored copy it resolves known paths, moves a page, rolls back a move recorded before the snapshot, and allocates a new page whose id follows on;
- the comparison is shown to be non-vacuous: after those writes, verification reports differences in `pages` and `route_changes`;
- the source database was only read: its manifest is unchanged at the end.

A second test shows that the guards refuse `dd.reset`, `dd.snapshot --restore` and `dd.rebuild` against a database holding routing state. They accept a covering snapshot, and refuse a stale one, one without marks, and a missing one.

## Limits

- **Scale.** The manifest streams through a server-side cursor in constant memory. Its running time against the full corpus (about 3.7 million objects and 3.9 million assertion revisions) has not been measured.
- **The comparison is of identities and references, not every column.** Bodies are compared by hash. Bookkeeping timestamps are left out, except on append-only history, where the timestamp is part of the record.
- **A dump taken while routing writes continue** is still consistent, because pg_dump reads one database snapshot. Its recorded marks then lag the database, so the guard refuses to treat it as covering, and you snapshot again.
