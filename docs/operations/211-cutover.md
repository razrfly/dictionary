# #211 cutover: run sheet and rollback, 7 October 2026

**Status:** the installation runs from the external drive. The internal one stays as it was through the acceptance window. It is reclaimed only item by item, on the owner's word.

The plan is [`211-stage-1.md`](211-stage-1.md), and the interface is [`installation.md`](installation.md). The records of stages 3–6 are on [#211](https://github.com/razrfly/dictionary/issues/211).

## The installation after the move

| What | Where |
|---|---|
| Cluster | `system_identifier` **7693849764459364596**, PostgreSQL 18.2 (Postgres.app's binaries), port **5434** |
| Data directory | `/Volumes/LLM Models/dictionary/postgres/18/data`, on volume `F7FDE75A-3FE9-43D9-AC1E-71FDDEDBAF31` (`/dev/disk5s1`) |
| Server log | `/Volumes/LLM Models/dictionary/postgres/18/postgresql-5434.log` |
| Start at login (D2) | user LaunchAgent `com.razrfly.dictionary.postgres-5434` (`~/Library/LaunchAgents/`): Postgres.app's `pg_ctl`, `RunAtLoad`, `StartOnMount`. With the drive absent, it starts nothing |
| Databases | `devils_dictionary_v2` (restored exactly, then migrated to `20260927220937`), `devils_dictionary_runtime_bench` and `_b` (restored exactly), and test partitions |
| Settings | `wal_sync_method=fsync_writethrough` (D3); 5432's memory settings (D4); normal running: `max_wal_size=2GB`, default `checkpoint_timeout` |
| Checkout | `/Volumes/LLM Models/dictionary/src/dictionary`, with its `data/`, `priv/replay` and `.env`; its Claude memory is under `~/.claude/projects/-Volumes-LLM-Models-dictionary-src-dictionary` |
| Defaults (D11) | `config/dev.exs` and `config/test.exs` reach 5434 when `DD_DATABASE_PORT` is unset |
| Model service (D12) | bound to `devils_dictionary_runtime_bench` on 7693849764459364596 (`run/authority.json`) |
| Baseline bundle | `/Volumes/LLM Models/dictionary/bundles/2026-10-05-v2`, `MANIFEST.json` `5d36203469089f05bee510eb35c6ef126fd5e8ca2adf7384b3674a5bc98e63ff` |
| Second copy (D14) | `~/Backups/dictionary/bundles/2026-10-05-v2` on the internal disk, the same digest, verified there |

**The old installation, unchanged until the reclaim:**
- the internal cluster 7607810074859095446 on 5432, whose `devils_dictionary_v2` is still at `20260927131023` (24 migrations);
- the old checkout `~/Code/projects-2026/dictionary` at `16e35ca`, with its worktrees;
- the 5433 rehearsal cluster.

## Run sheet

Each step's check comes before the next step.

1. **The new cluster answers as itself:**

   ```bash
   mix dd.doctor --expect-cluster 7693849764459364596 --volume "/Volumes/LLM Models" --volume-uuid F7FDE75A-3FE9-43D9-AC1E-71FDDEDBAF31
   ```

   Run it from the external checkout. Every core check must pass, with no migration pending.
2. **Nothing writes to the old `v2`.** `pg_stat_activity` on 5432 shows no session on `devils_dictionary_v2`, and its counters are unchanged.
3. **The defaults switch (D11).** The change that makes 5434 the default merges, and the external checkout fast-forwards to it. The old checkout is not touched: it still defaults to 5432, and that is the rollback path.
4. **The model service rebinds (D12),** from the external checkout:

   ```bash
   DD_DATABASE=devils_dictionary_runtime_bench mix dd.runtime service start --rebind
   ```

   Then `service status` and `ready` check it.
5. **Every endpoint is verified before any write:**
   - the cluster (step 1);
   - the dev server from the external checkout on 4007, with Oban off, reading `devils_dictionary_v2` on 5434;
   - the model service on `127.0.0.1:11435`, bound to the new cluster;
   - a test partition on 5434.
6. **The acceptance window opens:** 7 days of normal use, recorded on #211 with its closing date.

## Rollback

**During the window,** the old installation is intact:
- `v2` on 5432 has not been written or migrated;
- the old checkout still defaults to 5432;
- the bundle and its second copy are verified.

To roll back:

1. **Stop every client of 5434:** the dev server, the model service, any `mix` task.
2. **Keep writes made since the cutover.** They are not in the source. Capture them before anything else:

   ```bash
   mix dd.bundle --source ecto://postgres@localhost:5434/devils_dictionary_v2 --root . --out "/Volumes/LLM Models/dictionary/bundles/<date>-v2-after-cutover" --volume "/Volumes/LLM Models" --volume-uuid F7FDE75A-3FE9-43D9-AC1E-71FDDEDBAF31
   ```

   Reconcile them deliberately. Switching back alone loses them.
3. **Point the clients back:**
   - work from the old checkout `~/Code/projects-2026/dictionary`, which defaults to 5432;
   - or, from the external checkout, export `DD_DATABASE_PORT=5432`.

   For the model service, `mix dd.runtime service start --rebind` against `devils_dictionary_runtime_bench` on 5432.
4. **Start nothing on `main` against the old `v2` until its two pending migrations are decided.** `main`'s development page for pending migrations would offer to apply them.
5. **Stop the new cluster:**

   ```bash
   launchctl bootout gui/$(id -u)/com.razrfly.dictionary.postgres-5434
   ```

   ```bash
   pg_ctl -D "/Volumes/LLM Models/dictionary/postgres/18/data" stop
   ```

   Its data directory, the bundles and the second copy are deleted only on the owner's word.

**After the reclaim** there is no internal copy to fall back to. Recovery is then a restore from the bundle (or from its second copy) onto a new cluster, by [`installation.md`](installation.md). Anything written since the bundle was taken is lost unless a newer bundle exists.

## Starting and stopping the cluster

- **Start, or start again:**

  ```bash
  launchctl kickstart gui/$(id -u)/com.razrfly.dictionary.postgres-5434
  ```

  `pg_ctl -D "/Volumes/LLM Models/dictionary/postgres/18/data" -l "/Volumes/LLM Models/dictionary/postgres/18/postgresql-5434.log" start` does the same by hand.
- **Stop:**

  ```bash
  pg_ctl -D "/Volumes/LLM Models/dictionary/postgres/18/data" -m fast stop
  ```

  The agent does not restart it. It has no `KeepAlive`, so a stop stays a stop until the next login, mount or kickstart.
- **Before ejecting the drive,** stop the cluster first. A mount of any volume starts it again (`StartOnMount`) if its data directory is present.
- **Using a Postgres.app server entry instead** (the D2 alternative): bootout and remove the agent first. Never run both for the same data directory.
- **macOS privacy control.** The first start from launchd, and the first dev server started by the Claude app's preview, each need the owner to allow access to the removable volume. Before that, the process waits in `open()` on `/Volumes/LLM Models`.
