# Routing recovery procedure

**Status:** supported procedure, 27 September 2026, for [routing issue #194](https://github.com/razrfly/dictionary/issues/194). It is exercised end to end by `test/devils_dictionary/routing/recovery_test.exs` against isolated, disposable databases. It was **rehearsed on the development corpus**, in [Stage 2A](stage-2/recovery-rehearsal.md) and again in the [recovery repair](stage-2/recovery-repair.md). Snapshot, restore and exact verification work at corpus scale, with routing and curation state. Re-projection (step 4) completes for every provider and keeps every identity, route and approval. On the development corpus it still writes a measured catch-up to today's materializers, which awaits the owner's decision ([proposal](stage-2/corpus-catch-up.md)).

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

The dump and its sidecar are each written to a partial file and renamed into place only when complete, the dump first. A snapshot that fails leaves an earlier one at the same path as it was, still restorable. A sidecar never vouches for bytes it does not describe: it records the dump's SHA-256, and a restore refuses a mismatch. A dump without the sidecar does not count.

These guards stop accidents. They do not stop an operator: naming a snapshot is a deliberate acknowledgement. The routing tables also refuse `TRUNCATE`, including one cascading from `objects`, unless a transaction sets `dictionary.allow_routing_truncate`. Only the test suite's reset does that. Production should also deny the application's database role TRUNCATE and trigger control.

## Procedure

Every step except the first writes only to a new, separate database.

A restored copy carries the source's queued and scheduled jobs. Tasks that start the application would otherwise run them against the copy, and the quotation verifier makes outbound requests. `mix dd.routing.verify` starts none of it: it opens its own connections through `Recovery.with_database/2`, starting `:ecto_sql` but not the application's Repo, Oban or the endpoint. For every other command on the copy, set `DD_NO_OBAN=1`, which starts Oban with no queues and no plugins. Never restore over the live database: the guard refuses without a covering snapshot, and you would lose whatever the snapshot does not hold.

1. **Quiesce, then snapshot the source.** Step 3 compares the copy with the **live** source, so the source must take no writes from here until step 3 is done.

   **Find the writers:** the source's connections in `pg_stat_activity`, and the local processes holding them (`lsof -iTCP:PORT`). Stop the application, its Oban node and any running tasks.
   - Stop a server in an interactive terminal (`iex -S mix phx.server`) through its owner, in that terminal.
   - **Never `SIGSTOP` a foreground terminal job.** The shell takes the terminal back. After `SIGCONT` the job reads the terminal as a background job and stops again (`SIGTTIN`), until someone types `fg` there.
   - A process that does not read the terminal (for example `mix run script.exs`) can be suspended with `SIGSTOP` and resumed with `SIGCONT`.

   **Prove the window was write-free:** the source's row counters must be equal before the snapshot and after the comparison. Use the sums of `n_tup_ins`, `n_tup_upd` and `n_tup_del` over `pg_stat_user_tables`. `pg_stat_database`'s `tup_*` counters also count catalog maintenance.

   The snapshot itself is read-only. It writes the dump and its `.routing.json` sidecar, which records the source as its server reports it (step 2).

   ```bash
   mix dd.snapshot --out ~/Backups/dictionary-routing.dump
   ```

2. **Restore into an isolated database.** The name must begin with `devils_dictionary`, and `DD_DATABASE` must name it.

   A restore drops its target first, so it must never land on the database the snapshot came from. A pre-routing source has no routing state for the routing guard to protect, so `Snapshot.restore!/3` makes this check itself, before dropping anything. `mix dd.snapshot --restore` makes it too.

   Names and endpoints cannot decide which database is which. A Unix socket and a TCP address reach the same server, and two servers can each hold a database of the same name. So the snapshot's sidecar records the source as its server reports it: the cluster's `system_identifier`, the database's name and oid, and the dump's size and SHA-256. The restore **refuses** when:
   - **always**, when the sidecar is malformed, or does not describe its dump: different bytes, or a header naming another database;
   - **when the target database exists**, and so would be dropped, if the sidecar is missing or from before identities were recorded;
   - when the target server's identity cannot be read, over the same endpoint `pg_restore` uses;
   - when the target is the source: the same cluster, with the same database name or oid. A renamed source is still the source.

   A restore to another database, or to a database of any name on another cluster, is allowed. A dump whose sidecar is missing or predates identities can be restored only into a database that does not exist yet, where nothing is dropped. That keeps an older snapshot usable as a rollback point. To restore it anywhere else, take the snapshot again with `mix dd.snapshot`.

   The identity probe, the drop and `pg_restore` all reach one endpoint. It is settled once, as Postgrex settles it: a `socket_dir`, or else `hostname` and `port`, defaulting to `PGHOST` and `PGPORT`. A `socket:` or `endpoints:` configuration, which the `pg_*` tools cannot follow, is refused.

   ```bash
   DD_DATABASE=devils_dictionary_restore mix dd.snapshot --restore ~/Backups/dictionary-routing.dump --database devils_dictionary_restore
   ```

   **Another local server.** Where the usual server lacks room for the copy, restore into a scratch cluster, and point the tasks at it with `DD_DATABASE_PORT`. Initialize the scratch cluster with the source's encoding and locale, then name the source by URL in step 3. Stage 2A did this; see the report.

   ```bash
   DD_DATABASE=devils_dictionary_restore DD_DATABASE_PORT=5433 mix dd.snapshot --restore ~/Backups/dictionary-routing.dump --database devils_dictionary_restore
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

   With the copy on another server, name the source by URL:

   ```bash
   DD_DATABASE=devils_dictionary_restore DD_DATABASE_PORT=5433 mix dd.routing.verify --baseline ecto://postgres:postgres@localhost:5432/devils_dictionary_v2
   ```

   **A source that predates the routing migration** has none of the six routing tables, and no record of the routing migration (`20260926193256`) in `schema_migrations`. Verification then compares the corpus exactly and reports **routing: not applicable**. That proves the corpus was recovered, and nothing about routing. The following all fail:
   - routing tables on one side only, or only some of them on either side;
   - the routing migration recorded with its tables gone, or the tables present without the migration, even when both databases match;
   - a database with no migration history.

   `mix dd.routing.verify` also refuses to compare a database with itself. It asks both servers which database each is, so a socket and TCP, or `localhost` and `127.0.0.1`, cannot disguise one database as two.

   To rehearse routing recovery from such a source, work only on copies:
   1. Prove the restore at the original schema, as above.
   2. Migrate the copy, never the source, and prove the migration changed nothing the copy held and added exactly what the migrations add, with `migration_check.exs` (`Routing.MigrationCheck`).

      The expected additions are not a list. They are what the same migrations add to an empty reference database, migrated over the same range of versions. Pin the boundary with `mix ecto.migrate --to`:
      - `--to 20260926193256` reproduces the routing-only rehearsal;
      - no `--to` checks current main, which adds #206's curation schema after routing.
   3. Add a marked routing fixture (`fixtures.exs`), then snapshot and restore that copy into a second one, and verify the pair: routing is then present on both sides and compared.

4. **Re-project the copy from its own records, in any provider order, and resolve.** `mix dd.materialize --all --resolve` re-projects every record of one source from the source records the copy holds. It then drains the pending edges that source wrote into assertions (the pass `mix dd.resolve` makes). Last, it asserts that nothing derived changed (scorecard M2) across every table the fingerprint covers, `pending_relations` included. Repeat it for each source, in whatever order:

   ```bash
   DD_NO_OBAN=1 DD_DATABASE=devils_dictionary_restore mix dd.materialize --source wikidata --all --resolve
   ```

   Without `--resolve`, the comparison leaves `pending_relations` out and prints that it did. Such a run cannot show a re-projection equal: it re-creates the pending edges that the build had already drained.

   Each run also counts what it did not project, by kind, in its report and its `import_runs` stats. Nothing is skipped silently:
   - `verifier_cache`: the quotation verifier's pinned Wikidata lookups (`Sources.CacheRecord`). These are evidence, never entities.
   - `label_missing`: a Wikidata item with no name in any language the source reads. The established entity keeps the name another source gave it, and no identity entry is made for it.

   Any other record that is not an entity payload stops the run.

   To exercise the replay path as well, replay the API sources **only from an archive exported from the copy itself**. The pinned `priv/replay` archive may be older than the snapshot, and would re-project different records:

   ```bash
   DD_NO_OBAN=1 DD_DATABASE=devils_dictionary_restore mix dd.export.replay --out /tmp/restore-replay --quiet
   ```

   ```bash
   DD_NO_OBAN=1 DD_DATABASE=devils_dictionary_restore mix dd.replay --dir /tmp/restore-replay --source wikidata
   ```

   **Why `--resolve`.** Materialization writes an edge whose target is still a string into `pending_relations`, and the resolve pass drains it into an assertion. A re-projection without it leaves every such edge re-created and waiting: Stage 2A found 2.48 million. Several records can attest one edge, each with its own provenance. The resolve pass chooses one attestation for the claim before it drains anything, by content: the first attesting record by external id, then the stated part of speech, the metadata and the method. So the claim changes neither with the order of the rows nor with the order in which records were first inserted.

   **On the development corpus** ([recovery repair](stage-2/recovery-repair.md)), every provider now re-projects to completion. Identities, references, routing history and curation approvals come through exactly. Wikipedia, Wikidata and Wiktionary still exit non-zero, because M2 finds derived state changed: the corpus was built by older materializers, and today's write rows and fields it never had. The difference is measured in full in the [catch-up proposal](stage-2/corpus-catch-up.md). Until the owner decides on it, a re-projection of that corpus is not expected to match its source.

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
- the copy exports its own replay archive, then re-projects with `mix dd.replay` and `mix dd.materialize --all --resolve`, **Wikidata before Wikipedia**. The test asserts that each source's three records were really replayed and re-materialized, in that order, that each materialization found every fingerprinted table identical, pending relations included, and then compares everything again in projected mode;
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

`RecoveryPreRoutingTest` covers databases that predate the routing migration, again on disposable databases:
- a pre-routing copy verifies exactly, with routing **not applicable**, and a changed reference or a moved unused sequence still fails;
- routing tables on one side only, or only some of them on either side, fail, even when every section matches;
- routing is judged by migration history too: two databases that both record the routing migration and both lost every routing table fail as inconsistent, and so do the tables without the recorded migration, or no migration history at all;
- a baseline named by URL on any server is read, not the configured database.

`RecoverySourceIdentityTest` holds a restore to the identity the server reports:
- the source is refused however it is reached — `127.0.0.1` for `localhost`, the Unix socket for TCP, `mix dd.snapshot --restore` — and after a rename, by its oid; every refusal comes before anything is dropped;
- another database on the same server may be restored over, and so may a database of the same name on a genuinely different cluster (a throwaway `initdb` cluster on a free port), which then verifies against the source across the two;
- a missing, malformed or legacy sidecar, a dump that is not the one its sidecar describes, a dump whose header names another database, and a target whose server cannot be read are refused;
- verification refuses to compare a database with itself, however the baseline is named.

`MigrationCheckTest` runs the real migrations over disposable databases, a copy holding corpus rows and an empty reference, from the development corpus's version to the pinned routing boundary and to current main. The copy passes exactly when it adds what the reference adds and keeps everything it had; an extra index, a changed row, a reference that started elsewhere, or a copy that migrated nothing fails.

## Limits

- **Scale.** Measured in Stage 2A on the development corpus (14 GB, 28.6 million rows), on one machine:
  - a full manifest takes about 70 s;
  - a snapshot takes about 80 s, for a 1.26 GB dump;
  - a restore takes 76–110 s;
  - an exact verification takes 73–88 s, the two manifests being taken at once.

  A restored copy is 9.45 GB, because a fresh restore carries no bloat.
- **Bodies are compared by hash.** `text`, `json`, `jsonb` and `bytea` columns are compared by MD5, which catches accidents, not an adversary.
- **Ownership and privileges are compared, but not restored.** Step 3 says how to make them match.
- **Schema definitions** are compared as Postgres deparses them. There is one exception: an `IN` list written `x = ANY ((ARRAY['a'::varchar, …])::text[])` is compared in the form a restored server re-parses it to (`ARRAY[('a'::varchar)::text, …]`), because it is the same condition. Nothing else is rewritten.
- **The routing migration was amended in place** while its branch was unmerged. A database migrated at an earlier head of the branch has the same version number and different constraints. The schema section reports that. Such a database can hold no real routing state yet, because nothing writes it before Stage 2, so the fix is to roll back that one migration and migrate again. The rollback refuses if any routing row exists.
- **The guards are conservative, not transactional.** Any routing change since the snapshot refuses, even one the operator would not care about. A write committed between the guard's check and the drop is still lost, which is why step 1 quiesces.
- **"Human" is an actor check.** The ledger and the database require a `user` actor for human-only operations. Any code holding the application's database role could still write rows naming a `user` actor. Separate database roles for the application and for reviewers would close that; Stage 1 does not add them.
