# #211 stage 1: inventory and executable plan, 5 October 2026

**Status:** a plan, awaiting the owner's review. Nothing has been captured, restored, moved, stopped or dropped. The only things written are a private evidence directory on the external drive and this session's own test partition. The interface the plan uses is [`installation.md`](installation.md), which is stage 2.

- **Baseline:**
  - `main` `16e35ca`;
  - `devils_dictionary_v2` on 5432 at schema `20260927131023` (24 migrations);
  - `main` expects exactly two migrations after preservation, `20260927200717` and `20260927220937`.
- **Inputs read:**
  - [#211](https://github.com/razrfly/dictionary/issues/211) in full;
  - the [28 September handoff](https://github.com/razrfly/dictionary/issues/211#issuecomment-5864603525) and the [5 October readiness check](https://github.com/razrfly/dictionary/issues/211#issuecomment-5994341607);
  - [the 28 September checkpoint](consolidation-checkpoint-2026-09-28.md) and [recovery](../routing/recovery.md);
  - [#209](https://github.com/razrfly/dictionary/issues/209) and [#130](https://github.com/razrfly/dictionary/issues/130), as requirement sources.
- **Private evidence:** `/Volumes/LLM Models/dictionary/private/2026-10-05-211-stage1/` (mode 0700). It holds the raw tables behind every number here: databases on both clusters, schema heads, settings, worktrees, unpushed commits, I/O runs, and the doctor's JSON.

## The source is quiet

Re-checked first, at 14:29:51 (+02). The only client backend on 5432 was the checking `psql` itself. There is no `beam.smp`, `ngrok` or `ollama` process, and nothing listens on 4007.

`v2`'s write counters (`n_tup_ins`, `n_tup_upd`, `n_tup_del` summed over `pg_stat_user_tables`) were **37,301,248 / 61,342,633 / 8,670,285** at 12:32:35Z. They were identical at 12:59:56Z and 12:59:59Z, either side of a read-only `mix dd.doctor` run against it. No session was left connected.

Two agent processes have a dictionary checkout as their working directory. Neither holds a database connection:
- a Claude session (pid 61805, started 14:27) in `stage-2-routing-audit-372bbd`;
- Codex (pid 30776, running since 27 September) in the main checkout.

## Inventory

**Sizes** are `du -sk` for files and `pg_database_size` for databases.

**Dispositions.** *Keep* means it stays where it is until the move is accepted. Nothing is dropped without the owner naming it. A merged branch or a database's name is not deletion authority.

### Source and Git

| Item | Measured | Owner | Destination | Preservation and verification |
|---|---|---|---|---|
| Main checkout `~/Code/projects-2026/dictionary` | 7.18 GB in all: `.git` 144 MB, `data/` 3.52 GB, `.claude/` 3.16 GB (its worktrees), `_build` 165 MB, `deps` 102 MB | owner | external checkout (D8) | on `main` `16e35ca`, equal to `origin/main`, clean |
| Local branches | 70 | — | travel with the repository | `git log --branches --not --remotes` |
| **Unpushed commits** | **9 commits on 7 branches**: `claude/143-spotify-music-6bb8a8` 1; `claude/144-kit-de9e9d` 1, `-phase1` 2, `-phase2` 3, `-phase3` 5 (stacked, so 5 distinct); `integ` 2 merges; `merge-154` 1 merge | owner | push, or fetch into the new checkout | the list is in the private evidence |
| Stashes | 0 | — | — | — |
| Registered worktrees | 13, below | — | — | — |

### Worktrees

| Worktree | Head | Size | Dirty / untracked | Process with it as cwd | Disposition |
|---|---|---:|---|---|---|
| main checkout | `16e35ca` main | (above) | clean | Codex 30776 and several shells | moves (D8) |
| `~/.codex/worktrees/b0a9` | `67be21a` detached | 17 MB | **`README.md` modified; `docs/encyclopedia/` untracked** | none | **preserve the local edits** (a patch into the evidence) before anything moves |
| `~/.codex/worktrees/routing-policy` | `0cd1114` detached, on `origin` | 294 MB | clean | none | Codex's; via its own Worktrees setting |
| `143-spotify-music-6bb8a8` | `9076b78` | 292 MB | `data` symlink | none | **unmerged, 1 unpushed commit**: keep |
| `144-kit-de9e9d` | `febfe30` `claude/144-kit-phase3` | 290 MB | `data` symlink | none | **unmerged, 5 unpushed commits**: keep |
| `172-final-sweep` | `8e695ad` | 329 MB | `data` symlink | none | merged (#215); removable with the owner's word |
| `212-exemplar-items-b549d7` | `a89c2ff` | 330 MB | `data` symlink | none | **#218/#223, open**: keep |
| `curation-persistence-196` | `697ac8a` `codex/consolidation-2026-09-27` | 263 MB | `data` symlink | none | superseded checkpoint branch: keep the branch, the worktree is removable |
| `dictionary-curated-opening-phase1-f69daa` | `7711e31` | 345 MB | `data` symlink | none | merged (#202): removable |
| `source-listing-ui-ef5442` | `0576800` | 355 MB | `data` symlink | none | merged (#226): removable |
| `stage-2-routing-audit-372bbd` | `a89c2ff` detached | 344 MB | `data` symlink | **Claude 61805** | its session's |
| `word-level-tier-shelves-720f8b` | `07c8a17` | 321 MB | `data` symlink | none | merged (#187): removable |
| `dictionary-consolidation-stages-1-2-38c750` | this branch | ~220 MB | — | this session | becomes the stage 2 PR |

Every `data` entry is an untracked symlink to the main checkout's `data/`.

`.claude/settings.local.json` is per-worktree tool configuration, not evidence. `~/.codex/worktrees` holds 2.89 GB in all; only two of its checkouts are dictionary's.

### Databases, 5432: the shared internal cluster

- **Identity:** `system_identifier` 7607810074859095446, Postgres.app 18.2.
- **Data directory:** `~/Library/Application Support/Postgres/var-18`, on the internal disk.
- **Size:** 155 databases, 119.1 GB, of which 123 are dictionary's, 29.4 GB.
- **Other projects:** `cinegraph_dev` 48.1 GB, `volfefe_machine_dev` 18.0, `argus_dev` 17.6, `eventasaurus_dev` 5.1, `recordtemple_dev` 0.3, and their test databases. **Out of scope and untouched.**
- **Locale:** every database is UTF8 with the ICU provider, `en_US.UTF-8`, `en-US`, and collation version **153.128**, both recorded and actual.
- **Roles:**
  - `postgres`: superuser with every attribute;
  - `holden`: superuser, login, createdb, createrole; not replication or bypassrls.

| Database | oid | GB | Schema head | What it is | Proposed disposition |
|---|---:|---:|---|---|---|
| `devils_dictionary_v2` | 31334772 | 14.74 | `20260927131023` (24) | **the working corpus** | **moves** by `restore` (D1) |
| `devils_dictionary_dev` | 30888363 | 3.42 | `20260905115153` (2); no `citext` | Gate 0 baseline named in `config/dev.exs` | bundle it; move it, or keep it as a bundle only (D6) |
| `devils_dictionary_74_verify` | 31448564 | 4.46 | `20260909134659` (7) | #74 rebuild verification, cited in `docs/rebuild/` | bundle it as an archive; drop after acceptance if authorized |
| `devils_dictionary_bing135` | 37400859 | 4.46 | `20260912164611` (15); owner `holden`; **no `TimeZone` setting** | #135 trial copy | the same |
| `devils_dictionary_runtime_bench`, `_b` | 43681931, 43779816 | 0.015 each | `20260927131023` (24) | #210 runtime evidence; **the model service's authority names `runtime_bench`** | move both (D6, D12) |
| `devils_dictionary_ex212` | 46364939 | 0.015 | `20260927204902`, which is #218's unmerged migration | #212's work, PRs open | keep until #212 lands (D6) |
| `devils_dictionary_ex181`, `_ex181b2` | 40077253, 40408120 | 0.017 each | `20260924005117` | #181, merged | drop if authorized |
| `devils_dictionary_test*` | — | 2.23 in all | various | 114 test partitions, including this session's `_test_b211` | drop as a batch when no session uses them, if authorized; tests then run on the new cluster (D11) |

Every dictionary database on 5432 has `TimeZone=Etc/UTC` as a database-level setting, except `bing135` and `ex181b2`. `ecto_sql`'s `storage_up` sets it; the server default is `Europe/Warsaw`. **`pg_dump` without `--create` does not carry it.** A `createdb` plus `pg_restore` would silently move every timestamp into local time. The contract below compares it, and `dd.bootstrap` applies it.

### Databases, 5433: the rehearsal cluster, already external

- **Identity:** `system_identifier` 7690164109148229279, the same Postgres.app 18.2 binaries.
- **Data directory:** `/Volumes/LLM Models/dictionary-stage2a/pgdata`.
- **Process:** started with `pg_ctl` on 27 September at 15:08 (pid 61450), with no launcher.
- **Size:** 36 databases, 310.5 GB: 35 dictionary copies and `postgres`. Twenty-eight are 10–14 GB corpus copies; seven are schema-only references.
- **Locale:** the same ICU 153.128.
- **Roles:** **only `postgres`; there is no `holden`.**
- **Authentication:** `trust` for every local connection.
- **Read-only copies:** six carry `default_transaction_read_only=on`: `stage2a_baseline`, `stage2r_base`, `_c1`, `_c1_899`, `_source` and `_w1prefix_frozen`.

Their dispositions are the 28 September checkpoint's. It is unchanged since: no database was created, dropped or written there today. They are external already, so the move does not depend on them.

### Archives, inputs, models, evidence, state

| Item | Where | Size | Disposition |
|---|---|---:|---|
| `data/raw-wiktextract-data.jsonl.gz` | main checkout `data/` (internal) | 2.83 GB | **not re-downloadable** (`url_is_rolling`). Its SHA-256 matches the pin (`4c27d202…`, measured today) → into the bundle |
| `data/english-wordnet-2025-plus-json.zip` | the same | 11 MB | into the bundle |
| `priv/replay/*.jsonl.gz` | main checkout (internal) | 97 MB, 6 archives + `MANIFEST.json` | into the bundle |
| `data/audits/` | main checkout (internal) | 753 MB: `2026-09-28-219` 438, `2026-09-27-stage2r` 282, others 34 | private evidence → external |
| Stage 2 dumps | `/Volumes/LLM Models/dictionary-stage2a/{dumps,stage2r/dumps}` | 2.46 + 9.82 GB | already external; none is the capture |
| Stage 2 replay exports | the same, `replay/` | 57 + 344 MB | already external |
| Runtime: Ollama 0.34.4, models, run state | `/Volumes/LLM Models/dictionary/{bin,ollama,run,downloads}` | 0.51 + 9.75 + 0.0004 + 0.16 GB | already external; inventoried in the bundle, not copied |
| Runtime authority | `…/dictionary/run/authority.json` | — | bound to `devils_dictionary_runtime_bench` on 7607810074859095446. **Rebind deliberately after the move** (D12) |
| 27 September private inventories | `…/dictionary/private/2026-09-27-consolidation` | small | kept |
| `.env` | main checkout | 931 B | copied privately; never in a bundle |
| Claude project state | `~/.claude/projects/*dictionary*` | 40 directories, 606 MB; the main project's 150 MB, with its memory | **keyed by checkout path** (D8) |
| Codex sessions | `~/.codex/sessions`, `archived_sessions` | 1.66 GB, 33 MB | shared with other projects: a measured exception |
| Hex and Mix caches | `~/.hex`, `~/Library/Caches/mix` | 59, 48 MB | shared, small: an exception |

## Destination and I/O

**`/Volumes/LLM Models`:**

| Property | Value |
|---|---|
| Device | `/dev/disk5s1`, APFS |
| Volume UUID | `F7FDE75A-3FE9-43D9-AC1E-71FDDEDBAF31` |
| Connection | PCI-Express; `Device Location: External`; SSD; fixed; not encrypted |
| Mount options | `nodev, nosuid, noowners` |
| Capacity | 2.0 TB container; **1.42 TiB available** (`df`) |

`noowners` means file ownership is not enforced on this volume. The evidence directories' `0700` keeps nobody out but on a single-user machine; that is the boundary today.

`/Volumes` is `root:wheel 755`. An absent mount point cannot be recreated by an ordinary user, so a missing drive cannot silently become an internal directory.

**Internal disk:** 15.3 GiB available, up from 13 GiB after D2. Every bulk artifact of the plan goes to the external drive. Internal temporary space needed is about nil: PostgreSQL's temporary files live in the new cluster's data directory.

| Measurement, 5 October | External | Internal |
|---|---|---|
| sequential write, 8 GiB of zeros + `sync` | 2.65 s, about 3.2 GB/s | — |
| read, 1.26 GB dump | 0.39 s (may be cache) | — |
| read, 2.83 GB input | — | 0.62 s (may be cache) |
| **cross-volume copy**, 2.83 GB, internal → external, + `sync` | **1.27 s, about 2.2 GB/s** | |
| SHA-256 of 2.83 GB with `shasum` | 4.85 s, CPU-bound | |
| `pg_test_fsync`: `open_datasync`, the clusters' setting | 7,973 ops/s (125 µs) | 24,518 ops/s (41 µs) |
| `pg_test_fsync`: `fsync_writethrough` (`F_FULLFSYNC`) | **252 ops/s (3.96 ms)** | 247 ops/s (4.05 ms) |

On macOS, `open_datasync` does not force the drive's cache to stable storage; only `fsync_writethrough` does. Both clusters use the former. On an external drive, a pulled cable is the realistic failure (D3).

**Expected sizes**, from earlier measurements; none was re-measured today:
- a custom-format dump of `v2`: 1.26 GB (27 September);
- a restored copy: 9.98 GB (the 5433 copies);
- a restore: 76–110 s;
- an exact verification: 73–88 s (Stage 2A).

## Destination decision (D1): a new dedicated external cluster

**Recommended:**
- data directory `/Volumes/LLM Models/dictionary/postgres/18/data`;
- port **5434**, free today;
- created by `mix dd.bootstrap.cluster` from the bundle's record, with the same Postgres.app 18.2 binaries.

**Not the 5433 rehearsal cluster.**

| | New cluster on 5434 | Reuse 5433 |
|---|---|---|
| Identity | new `system_identifier`: old, rehearsal and new cannot be confused by the guards or the runtime authority | shares an identity with 35 rehearsal copies |
| Contents | only the installation | 310.5 GB of disposable copies, six read-only by default, beside the working database |
| Later reclaim | dropping rehearsal copies never touches the working cluster | rehearsal drops happen next to the working database |
| Roles | `postgres` and `holden`, as recorded | `holden` missing |
| Settings | chosen deliberately (D3, D4) | rehearsal tuning: `shared_buffers` 4 GiB, `max_wal_size` 8 GB, `checkpoint_timeout` 15 min |
| Collation | ICU 153.128 (same binaries; checked by the tool) | ICU 153.128 |
| Cost | one more server process, and a start-up mechanism (D2) | none |

Either way the encoding, ICU locale, extensions and referenced roles are the same, because `dd.bootstrap` refuses otherwise.

## Path and configuration map

| What | Today | Set by | Embedded? | After the move |
|---|---|---|---|---|
| dev database name | `devils_dictionary_v2` | `DD_DATABASE` | default in `config/dev.exs` | unchanged |
| dev database server | `localhost:5432` | `DD_DATABASE_PORT` | default 5432 in `config/dev.exs`; host, user and password hard-coded | **5434**: export it, or change the default at cutover (D11) |
| test databases | `devils_dictionary_test<partition>` on `PGPORT` or 5432 | `MIX_TEST_PARTITION` | **`config/test.exs` sets no port** | add `DD_DATABASE_PORT` to `config/test.exs` so tests run externally (D11) |
| production | `DATABASE_URL` | `config/runtime.exs` | env | out of scope |
| HTTP port | 4007 | `PORT` | default | unchanged |
| background jobs | Oban queues on | `DD_NO_OBAN=1` turns them off | — | off until the restored copy is accepted |
| archived inputs | `data/…`, relative to the working directory | `priv/sources/MANIFEST.json`; `sources.config` rows store the same relative paths | relative | the external checkout's `data/` |
| replay archive | `priv/replay` | `--dir`, `--out`; `dd.rebuild` hard-codes it | relative | the external checkout |
| snapshots | `priv/snapshots` | `--out` | relative default | bundles on the external drive |
| routing policy | `priv/routing` | **absolute path baked in at compile time** (`Routing.Policy`) | yes | recompile after moving; `dd.doctor` checks it |
| curation runtime | `/Volumes/LLM Models/dictionary/{bin,ollama,run}`, `127.0.0.1:11435` | `:curation_runtime` in `config/config.exs` | **four absolute paths**, repeated in `Runtime.Endpoint`'s defaults; no environment variable | already external. One root setting would remove the duplication (D13) |
| runtime authority | `run/authority.json` → `runtime_bench`, cluster 7607810074859095446 | `mix dd.runtime service start --rebind` | — | rebind (D12) |
| scratch cluster | `…/dictionary-stage2a/pgdata`, port 5433 | `DD_DATABASE_PORT` | docs only | unchanged |
| **bundles** (new) | — | `--out`, `--volume`, `--volume-uuid` | **never defaulted** | `/Volumes/LLM Models/dictionary/bundles/<date>-<db>` |
| **dedicated cluster** (new) | — | `--data-dir`, `--port` | never defaulted | `/Volumes/LLM Models/dictionary/postgres/18/data`, 5434 |
| evidence | `data/audits` (internal), `…/dictionary/private` | — | — | `…/dictionary/private` |
| `.env` | main checkout | `config/runtime.exs` reads `../.env` relative to itself | relative | the external checkout |
| `_build`, `deps` | per checkout | Mix defaults | — | follow the checkout |
| temporary files | `System.tmp_dir!` (tests' throwaway clusters, artwork progress) | `TMPDIR` | — | small; optionally `TMPDIR` external |
| worktrees | `.claude/worktrees` (Claude), `~/.codex/worktrees` (Codex) | each agent app | — | Claude follows the checkout; Codex has its Worktrees setting |

## Comparison contract

Implemented as `Installation.State`; the full statement is in [`installation.md`](installation.md#the-comparison-contract). For `v2` it covers:

- **69 tables, every column**, in primary-key order. That includes `schema_migrations`, `oban_jobs` (980 rows: 977 completed, 2 cancelled, 1 discarded) and `oban_peers`. The latter holds one stale row from the killed 4007 node, and is an **unlogged** table, which `pg_dump` dumps by default;
- the schema, with owners (all 361 relations and 136 functions belong to `postgres`) and privileges (no non-default ACL, no default ACL);
- **54 sequences**, by state;
- routing: the tables are present and empty (0 pages, 0 route changes, 0 decisions), so the resolution digest is of an empty set;
- the database's properties: UTF8, ICU `en-US`, `en_US.UTF-8`, **collation version 153.128 recorded and actual, compared both ways**, owner `postgres`, the default ACL, connection limit -1, no comment;
- its one setting, `TimeZone=Etc/UTC`;
- extensions: `citext` 1.8, `pg_trgm` 1.6, `plpgsql` 1.0;
- the referenced role, `postgres`, with its attributes. **Restore mode also requires `holden`**, as a role of the source cluster.

**Excluded:** the database's oid; the name, in `init` mode only.

**Not part of the database contract**, and compared separately: file hashes. The bundle's manifest covers the dump, the state, the inputs and the replay archive. `priv/sources/MANIFEST.json` and `priv/replay/MANIFEST.json` cover the checkout.

**Collation version.** The source uses ICU. A restore onto a server whose ICU version differs is **refused** rather than compared afterwards: indexes on text would be built under another collation, while the rows compared equal. A deliberate reindex would be a separate decision.

## Quiescence procedure

Everything is read-only until step 5.

1. **Owners stop their writers,** each from its own terminal or app. Today that means confirming that nothing is started: no dev server, no tunnel, no preview, no runtime service. The two agent processes listed above are asked to stay off `v2` (D9).
2. **Check:**

   ```bash
   psql -X -p 5432 -d postgres -Atc "select pid, application_name, client_addr, state from pg_stat_activity where datname = 'devils_dictionary_v2' and pid <> pg_backend_pid()"
   ```

   The answer must be empty.

   ```bash
   lsof -nP -iTCP:4007 -sTCP:LISTEN
   ```

   ```bash
   pgrep -fl 'beam.smp|ngrok|ollama'
   ```

   Neither may find anything for dictionary.
3. **Record the counters.** `mix dd.bundle` does it itself (step 5). The operator also keeps the `psql` line from "The source is quiet" above, before and after, in the evidence.
4. **`mix dd.doctor`** against the source must report it usable with exactly the two pending migrations.
5. **Capture.** `mix dd.bundle` refuses if any other session is connected at the start. It refuses to finish if, by the end, any of these moved:
   - the write counters;
   - the sequences;
   - the user catalog;
   - the connected sessions.

   Sequence values and catalog definitions are not read under the dump's snapshot, so this is what makes them exact. The manifest records both readings.
6. The source stays quiet **until the restored copy is verified** (stage 3), because `mix dd.routing.verify` compares the copy with the live source as a second, independent check.

**Not used:** setting `default_transaction_read_only` on `v2`. It would be a write to the source, and would change the database setting the bundle records.

## Rollback procedure

- **Before cutover,** nothing has changed on the source: the move reads it only. Rolling back is stopping the new cluster:

  ```bash
  pg_ctl -D "/Volumes/LLM Models/dictionary/postgres/18/data" stop
  ```

  Its directory and the bundle are deleted only by the owner's decision.
- **After cutover** (clients on 5434), roll back as follows:
  1. Stop every client of 5434.
  2. Point them at 5432: unset `DD_DATABASE_PORT`, or revert the default.
  3. Start nothing on `main` against `v2` until its two pending migrations are decided. `main`'s development page for pending migrations would offer to apply them; that hazard predates this work.
- **Writes made on the destination after cutover are not in the source.** Before rolling back, capture them with `mix dd.bundle --source ecto://postgres@localhost:5434/devils_dictionary_v2 …`, and reconcile them deliberately. Switching back alone loses them.
- **The source stays unchanged,** unmigrated and with its dumps, through the acceptance window: a later stage records how long, and the reclaim follows. The two pending migrations are applied **only on the destination**, as a recorded step after the exact restore passes.

## The commands, as they exist (stage 2)

The placeholders are the bundle path (`<bundle>`), the approved manifest digest (`<digest>`) and the new cluster's identifier (`<new-id>`). Each step refuses before writing if its checks fail.

**0. The source's readiness:**

```bash
mix dd.doctor
```

**1. Capture.** Run it once the source is quiet and the owner has approved:

```bash
mix dd.bundle --source devils_dictionary_v2 --root ~/Code/projects-2026/dictionary --out "/Volumes/LLM Models/dictionary/bundles/<date>-v2" --volume "/Volumes/LLM Models" --volume-uuid F7FDE75A-3FE9-43D9-AC1E-71FDDEDBAF31 --models-root "/Volumes/LLM Models/dictionary/ollama"
```

```bash
mix dd.bundle --verify "<bundle>"
```

**2. The dedicated cluster:**

```bash
mix dd.bootstrap.cluster --bundle "<bundle>" --expect-manifest-sha256 <digest> --data-dir "/Volumes/LLM Models/dictionary/postgres/18/data" --port 5434 --volume "/Volumes/LLM Models" --volume-uuid F7FDE75A-3FE9-43D9-AC1E-71FDDEDBAF31 --setting wal_sync_method=fsync_writethrough …
```

**3. Restore the installation:**

```bash
mix dd.bootstrap --mode restore --bundle "<bundle>" --expect-manifest-sha256 <digest> --target ecto://postgres@localhost:5434/devils_dictionary_v2 --target-cluster <new-id> --volume "/Volumes/LLM Models" --volume-uuid F7FDE75A-3FE9-43D9-AC1E-71FDDEDBAF31 --jobs 8 --report "/Volumes/LLM Models/dictionary/private/<date>-211-capture/restore.json"
```

**4. Independent second checks**, against the still-quiet source:

```bash
DD_DATABASE_PORT=5434 mix dd.routing.verify --baseline ecto://postgres:postgres@localhost:5432/devils_dictionary_v2
```

```bash
DD_DATABASE_PORT=5434 mix dd.doctor --expect-cluster <new-id> --volume "/Volumes/LLM Models" --bundle "<bundle>" --deep
```

The same bundle-and-restore pair moves `devils_dictionary_runtime_bench` and `_b`, with `--no-inputs`, and any database the owner names in D6.

Not part of stage 2, and still to come:
- the migrations step;
- the checkout and agent-state move (D8);
- cutover, the rebind (D12), and the representative reads and writes;
- the second clean target and the failure drills;
- the reclaim.

## Decisions owed before the capture

| # | Decision | Recommendation |
|---|---|---|
| D1 | Destination: a new dedicated cluster, or the 5433 rehearsal cluster | new cluster, `…/dictionary/postgres/18/data`, port 5434 |
| D2 | How the new cluster starts after a reboot: a Postgres.app server entry, a launchd job, or `pg_ctl` by hand | a Postgres.app server entry, the owner's to add; with the drive absent it fails to start rather than falling back |
| D3 | Durability on the external drive: `wal_sync_method = fsync_writethrough` (252 commits/s, measured) or the default `open_datasync` (7,973/s, not flush-safe on macOS) | `fsync_writethrough`: bulk imports commit in large transactions, and a pulled cable is the realistic failure. Re-measure import time in stage 5 |
| D4 | The new cluster's resources: match 5432 (`shared_buffers` 16 GiB, `max_connections` 300, `work_mem` 128 MB, `maintenance_work_mem` 2 GiB), or smaller | match 5432 for the move, so performance comparisons mean something; revisit after |
| D5 | Authentication: `trust` on localhost (as both clusters today) or passwords | `trust` for the move; passwords are a separate, deliberate change |
| D6 | Which databases move | `v2`, `runtime_bench`, `runtime_bench_b`: restore. `dev`, `74_verify`, `bing135`: bundle each as an archive, and decide on restoring `dev`. `ex212`: keep with #212. `ex181`, `ex181b2`, and the test partitions: drop after acceptance, if authorized |
| D7 | Bundle contents | the inputs (2.84 GB) and the replay archive (98 MB): yes. Models: inventory only |
| D8 | Moving the checkout and agent state | a fresh clone on the external drive. Fetch the 7 branches with unpushed commits from the old checkout (or push them), save the Codex `b0a9` edits as a patch, recreate the worktrees that are needed, and copy the Claude project memory to the new path's key. The old checkout stays read-only until acceptance |
| D9 | The quiet window | the Claude session in `stage-2-routing-audit-372bbd` and Codex in the main checkout confirm they stay off `v2`. The capture itself is measured in minutes |
| D10 | This interface | review the stage 2 PR before it is used on the corpus |
| D11 | Where tests and the dev server point after cutover | `DD_DATABASE_PORT` in `config/test.exs`, and 5434 as the dev default, changed at cutover rather than now |
| D12 | The runtime's database binding after the move | rebind to `runtime_bench` on the new cluster, explicitly: `mix dd.runtime service start --rebind` |
| D13 | One configurable root for the curation runtime's four paths | yes, as a small follow-up; not needed for the move |

## Measured, and assumed

**Measured today:**
- the source's quiet state and write counters;
- both clusters' identities, versions, settings and roles;
- every database's size, oid, locale, collation versions and settings, and every dictionary database's schema head and extensions;
- `v2`'s owners, ACLs, tables, sequences, functions, triggers, unlogged tables, Oban rows and routing rows;
- the worktrees: heads, dirt, sizes and processes;
- unpushed commits and stashes;
- every directory size quoted;
- the destination's identity, mount options and free space;
- the I/O and fsync figures;
- the Wiktionary input's SHA-256;
- the ports.

**Exercised, on disposable databases only:** the stage 2 interface. That covers a capture, `init` and `restore` (onto a throwaway cluster made by `dd.bootstrap.cluster`), the refusals, the resume, the transfer and the doctor. The suite is in [`installation.md`](installation.md#tests).

**Assumed, not measured:**
- The capture, restore and verification at corpus scale: the times and sizes above come from Stage 2A and the 5433 copies, not from this interface.
- That a `pg_dump` **with owners and privileges** of `v2` restores to an exactly equal schema section. This holds on test databases; the corpus has only `postgres` as owner.
- That a Postgres.app server entry accepts a data directory on this volume and fails cleanly without it (D2).
- That the drive enclosure honours `F_FULLFSYNC`: `pg_test_fsync` measures speed, not durability.
- The ICU version of a cluster not yet created. `dd.bootstrap.cluster` and `dd.bootstrap` check it rather than assume it.
- The size of `.claude/worktrees` after D8, and whether Codex's Worktrees setting covers its whole state. Not inspected.
