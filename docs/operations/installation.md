# Moving and setting up an installation

**Status:** the interface of [#211](https://github.com/razrfly/dictionary/issues/211) stage 2, built 5 October 2026. These commands exist and are tested. They have **not** been used on the working corpus yet: the capture, the restore and the cutover each wait for the owner's review. The stage 1 inventory and plan are in [`211-stage-1.md`](211-stage-1.md).

The requirements come from [#130](https://github.com/razrfly/dictionary/issues/130) (a bundle, a doctor, one setup path) and [#209](https://github.com/razrfly/dictionary/issues/209) (moving storage to the external drive). The point of both: moving the dictionary uses the same reusable process a future machine will use, and that process is checked rather than trusted.

## The four commands

| Command | What it does | Writes |
|---|---|---|
| `mix dd.doctor` | Is this installation ready? Read-only. | nothing |
| `mix dd.bundle` | Captures an installation into one directory, and verifies or copies a bundle. | the bundle directory, on the external volume |
| `mix dd.bootstrap.cluster` | Creates the dictionary's own PostgreSQL cluster from a bundle's record. | a new data directory, on the external volume |
| `mix dd.bootstrap --mode …` | Restores, initialises or prepares a rebuild from a bundle. | a new database; inputs, if asked |

`mix help <task>` documents each one. None of them starts the application, an Oban node, the endpoint or a model. None of them reads a value from `.env`; the doctor reads its key names only.

## Three modes, and only one is the move

| Mode | Use | The result |
|---|---|---|
| `restore` | **Restore this exact installation.** The migration path. | The same database name on **another cluster**, which is pinned by its `system_identifier`, on the external volume. Equal to the captured state in every section, the roles included. |
| `init` | **Initialise a new development installation** from an approved bundle. | Any `devils_dictionary*` name on any server except the source. The same exact comparison; only the name may differ. |
| `rebuild` | **Rebuild from pinned inputs.** Proves reproducibility. | Checks the inputs against this checkout's pins and prints the `mix dd.rebuild` commands for an empty target. It restores nothing. |

A rebuild renumbers every registry object. It never reproduces routing or curation state ([ADR 0004](../adr/0004-public-routing.md) §8, [recovery](../routing/recovery.md)), so it never stands in for a restore.

## What a bundle is

```text
<bundle>/
  MANIFEST.json                 written last; its SHA-256 is what gets approved
  db/<database>.dump            pg_dump, custom format, owners and privileges kept
  db/<database>.state.json      the state that dump holds (the comparison contract)
  inputs/data/…                 the archived inputs git does not carry
  inputs/priv/replay/…          the replay archive and its MANIFEST.json
```

- **One snapshot, two descriptions.** A repeatable-read transaction on the source exports its snapshot. Then `pg_dump --snapshot` and the state capture run at the same time inside it, so the state describes exactly the rows in the dump.
- **A quiet window covers the rest.** Sequence values and catalog definitions are not read under a snapshot. A `nextval` that writes no row (an upsert that does nothing) also moves no write counter. So the capture fingerprints three things before and after:
  - every sequence's state, and the user schemas' catalog rows by `xmin`;
  - the write counters;
  - the connected sessions.

  An installation bundle is finished only if all three are unchanged and nobody else connected. `--allow-unquiet` records an unquiet window instead, for a rehearsal. Such a bundle is not a baseline, and a later run that requires quiet takes the capture again rather than reusing it.
- **Bound by size and SHA-256.** The manifest lists every file with its size and SHA-256, the dump and the state file included. `mix dd.bundle --verify` checks them all. It also checks that the dump's header names the source database, and that the dump holds data for every table the state says has rows.
- **Approved by digest.** The manifest's own SHA-256 is printed when it is written. `--expect-manifest-sha256` pins it in every later step, so only the approved bundle is used.
- **Inputs by their pins.** The bundle carries:
  - the inputs that `priv/sources/MANIFEST.json` marks `committed: false`. These are the WordNet zip and the Wiktionary dump. The dump's URL is rolling, so it cannot be downloaded again;
  - the replay archive, by `priv/replay/MANIFEST.json`.

  Each is checked against its pin before it is copied.
- **Models are inventoried, not copied.** `--models-root` records every model manifest and blob with its size and digest. The weights are already on the external volume.
- **Private.** A bundle holds a full working database. Never publish one or attach it anywhere, whether or not `.env` is in it (it never is). A public starter bundle would need its own data, rights and privacy scope.

## The comparison contract

`DevilsDictionary.Installation.State` is the contract of #211 §3. A captured state holds:

- **every table, every column**, in primary-key order, with text in byte order. This covers registry identities and references, routing rows, curation records and approvals, and the migration history. It also covers **Oban's queue tables**: a moved installation keeps its jobs, although routing recovery leaves them out. Bodies (`text`, `json`, `jsonb`, `bytea`) are compared by MD5;
- **the schema**: owners, column types and collations, constraints and indexes with their validity, triggers with whether they fire, functions, sequence parameters, policies, object and default privileges as granted, and extension versions;
- **every sequence's** `last_value` and `is_called`;
- **routing**: whether its tables exist, and what every stored path and page id resolves to;
- **the database itself**:
  - encoding, locale provider, collate and ctype, and the ICU locale and rules;
  - the **recorded and actual collation versions**;
  - owner, privileges, connection limit and comment;
  - the **database-level settings**. `pg_dump` leaves these out without `--create`, and every `devils_dictionary*` database has `TimeZone=Etc/UTC` (Ecto's `storage_up` sets it; the server's default is `Europe/Warsaw`);
- **extensions**, with their versions and schemas;
- **the roles the database references** (owners, grantees, roles with settings in it), with their attributes. Passwords are never compared or carried.

Two things are excluded, and nothing else:

- the database's **oid**, which identifies a database rather than describing it;
- in `init` mode only, its **name**.

A difference is reported section by section, with rows for the schema and the sequences.

`mix dd.routing.verify` remains an independent second check. It compares the same tables, Oban's aside, in its own code.

**List settings** (`search_path`, `temp_tablespaces` and the other quoted-name lists) are given back element by element, as `pg_dump` gives them back. A value stored in the canonical form `ALTER … SET … TO` writes comes back byte for byte. A value stored raw through `SET … FROM CURRENT` may not be canonical, and then cannot be recreated exactly. The comparison reports it and the restore refuses it; it is never silently changed. No `devils_dictionary*` database has such a setting.

## Before anything is written

`dd.bootstrap` checks all of the following before its first write. A refusal leaves everything as it was.

- **The manifest:**
  - its format is known;
  - its digest is the approved one (required for `restore` and `init`);
  - it is an installation bundle;
  - every file matches it, by size and by SHA-256.
- **The target endpoint:**
  - it reaches the **pinned cluster**;
  - it is **not the source**: not the same cluster with the same name or oid. In `restore` mode it is not on the source's cluster at all;
  - in `restore` mode, the name is the source's own.
- **Compatibility:**
  - the same PostgreSQL major version;
  - a `pg_restore` at least as new as the `pg_dump` that wrote the dump;
  - **the same ICU collation version**. A different one would build text indexes under another collation;
  - every extension's **default** version on the target is the recorded one. `pg_dump` writes `CREATE EXTENSION` without a version;
  - every referenced role exists with the same attributes, and in `restore` mode every role of the source cluster;
  - the connecting role is a superuser, which restoring owners needs.
- **Room and placement:**
  - in `restore` mode, the target server's **data directory is on the external volume**. Its room is checked only when there is something to restore, so a repeated run on a full volume still reports;
  - inputs to place pass every check before anything is restored;
  - a report path must not exist yet.
- **The target database:**
  - **absent**: the restore proceeds;
  - **equal to the bundle**: reported as already restored, and left alone;
  - **anything else, even an empty database**: refused.

## How a restore runs, and how it resumes

1. A staging database, `<target>_dd_rs`, is created from `template0` with the recorded encoding, locale and owner. It is commented at once with a marker naming the bundle.
2. `pg_restore --exit-on-error` restores into it, owners and privileges included.
3. The database-level settings, connection limit and privileges are applied.
4. Its state is captured and compared with the bundle's.
5. Only when nothing differs (the marker standing in for the comment) is the staging database **renamed** to the target, keeping its oid.
6. Then the target is given the recorded comment, replacing the marker.

The rename comes before the comment. So the target name only ever holds a verified database.

- **Interrupted before the rename:** the next run finds the marked staging database, drops it and starts again.
- **Interrupted between the rename and the comment:** the next run finds the target in the bundle's state, still marked, and finishes it.
- **A staging database without this bundle's marker** belongs to someone else, and is refused.

Nothing else is ever dropped. `CREATE DATABASE` cannot share a transaction with its comment, so if marking fails, the database this run has just created is dropped again at once.

A session-level advisory lock on the target server, named for the target, lets only one bootstrap run at a time. A second one is refused before it changes anything. Placing inputs (`--place-inputs`) is checked in full before the restore begins: the volume, the room, every path inside the checkout, and no conflicting file.

**No migration is applied.** Migrating the restored database is a separate, recorded step, taken after the restore is accepted. The report lists which migrations this checkout carries that the bundle does not.

## Paths are inputs, never defaults

No bulk path has a default. Each command is told where to write, and checks that place first (`Installation.Volume`):

- the volume reports itself mounted at exactly that mount point;
- it is **not internal**;
- its `VolumeUUID` matches `--volume-uuid`;
- the path, or its nearest existing parent, is on that device and under that mount point once symlinks are resolved.

A directory at the mount path is not proof that the drive is mounted. Nothing is created until the check passes. `/Volumes` is not writable by an ordinary user, so a missing drive cannot be replaced by an internal directory by accident.

**One exception: the second copy.** A bundle that exists only on the external drive is lost with the drive. `mix dd.bundle --transfer <bundle> --out <dir> --internal --expect-manifest-sha256 <digest>` copies it to the internal disk, and nowhere else is the internal disk accepted. The destination must:

- copy a bundle that is itself on a mounted external volume;
- be on a mounted volume that diskutil reports internal (a second external drive is an ordinary `--volume` destination), and not a directory under `/Volumes` standing in for an absent drive;
- sit on another device than the bundle being copied;
- be outside every git repository, because a checkout is cleaned, re-cloned and reclaimed. Any `.git` on the way up counts, read from the filesystem rather than asked of git;
- leave at least 10 GiB free after the copy, because the internal disk also holds the system, its swap and the old cluster. `--reserve-gib N` names another floor, deliberately, on the command line.

`--expect-manifest-sha256` is required: the second copy is of an approved bundle.

The copy is verified there like any transfer, with the manifest written last (#211 D14).

| Input | Flag | Used by |
|---|---|---|
| source database | `--source NAME\|URL` | `dd.bundle` |
| bundle directory | `--out DIR`, `--bundle DIR` | all |
| external volume | `--volume MOUNT`, `--volume-uuid UUID` | all writers; `dd.doctor` |
| the internal disk, for the second copy only | `--internal`, with `--transfer` | `dd.bundle` |
| target database | `--target NAME\|URL` | `dd.bootstrap`, `dd.doctor` |
| target cluster | `--target-cluster ID`, `--expect-cluster ID` | `dd.bootstrap`, `dd.doctor` |
| cluster data directory and port | `--data-dir DIR`, `--port N` | `dd.bootstrap.cluster` |
| the installation's checkout | `--root DIR` | `dd.bundle`: its `data/` and `priv/replay` are bundled and its revision recorded, beside the task's own |
| server settings | `--setting key=value`, repeatable | `dd.bootstrap.cluster`: written with `ALTER SYSTEM` (a list of names element by element), made effective (a reload, and a restart when one is needed), then proven running from `postgresql.auto.conf` as the server last loaded it. On a running cluster they are checked, never changed. Repeated names, an extension's `ext.name` and the settings the task manages are refused before `initdb` |
| models | `--models-root DIR` | `dd.bundle` |
| inputs into a checkout | `--place-inputs DIR`, `--inputs-from DIR` | `dd.bootstrap` |
| report | `--report PATH` | `dd.bootstrap` |

A database name resolves against the configured server, which `DD_DATABASE_PORT` selects. An `ecto://` URL names its whole endpoint. Credentials it leaves out are the configured ones, so no password needs to appear in a command.

## Quickstart: a new development machine from an approved bundle

```bash
gh repo clone razrfly/dictionary && cd dictionary
```

```bash
mise install && mix deps.get && mix compile
```

```bash
mix dd.bundle --verify /path/to/bundle
```

```bash
mix dd.bootstrap --mode init --bundle /path/to/bundle --expect-manifest-sha256 <digest> --target devils_dictionary_v2 --place-inputs .
```

```bash
DD_NO_OBAN=1 mix dd.doctor --bundle /path/to/bundle
```

Then apply the pending migrations as a recorded step (`mix ecto.migrate`), copy `.env` privately, and start the server.

## The doctor

`mix dd.doctor` checks, each as **core** or **optional**:

| Check | What it reads |
|---|---|
| toolchain | Elixir and OTP against `.tool-versions` |
| pg_tools | `pg_dump`, `pg_restore`, `psql` against the server's major version |
| server | the cluster's identity, version and data directory, against `--expect-cluster` |
| volume | the data directory on `--volume` |
| database | it exists, its oid and size |
| locale | encoding, provider, locale, and **collation version drift** |
| db_settings | `TimeZone=Etc/UTC`, and the bundle's settings |
| extensions | `citext` and `pg_trgm`, and the bundle's versions |
| schema | migrations recorded against this checkout's: pending is a warning, unknown is a failure |
| state | with `--bundle --deep`, the full comparison contract |
| bundle | with `--bundle`, its files |
| inputs, replay | pinned files present; absent is optional, because only a rebuild or a replay reads them |
| build | a compiled build, **compiled for this checkout**. `Routing.Policy` bakes its path in at compile time, so a moved checkout must recompile |
| http_port | whether 4007 is free, and who holds it |
| jobs | what Oban would run if the server started (`DD_NO_OBAN`) |
| env | `.env` key names against `.env.example`, never values (optional) |
| runtime | the model service's binary, models and database binding (optional) |

It exits 1 when a core check fails. Optional failures report the installation as degraded, never unusable. `--json` gives the same report in machine-readable form.

It writes nothing:
- Every database question is a read-only transaction or a catalog read. The suite runs it against a database whose transactions are read-only by default, and checks that the write counters did not move.
- `--deep` opens one short-lived Repo pool to read the full state.
- It stats files, and hashes them only with `--deep`.
- It probes ports by connecting to them.

## Credentials

- `.env` holds the provider keys. It is never in a bundle. It is copied privately, and the doctor reports only which names it lacks.
- **Roles move without passwords.** `dd.bootstrap.cluster` creates the source cluster's roles with their attributes and memberships, and sets no password. Local authentication is `--auth`, `trust` by default, as on both local clusters today. A password, where one is wanted, is set deliberately afterwards through private configuration.
- No command line here needs a password. URLs may leave credentials out, and the configured ones are used.

## Tests

`test/devils_dictionary/installation/` uses disposable databases, a throwaway second cluster and temporary directories. Run it on a private partition:

```bash
MIX_TEST_PARTITION=_b211 mix test test/devils_dictionary/installation
```

`DD_DATABASE_PORT` picks the server the suite's databases live on, as it does for the development server. Unset, it is the server a connection without a port reaches: `PGPORT`, else 5432.

The suite covers each of the following:

- the binding between dump, state and manifest;
- an exact init, and a repeated init that changes nothing;
- that the comparison sees a changed row, sequence or setting;
- each refusal, with the proof that nothing changed: an unapproved manifest, the source, an unpinned cluster, a populated target, an empty foreign target, a corrupted or a missing dump;
- an interrupted restore, resumed, before or after its rename;
- a placement conflict, refused before any database exists;
- a second bootstrap, refused while one holds the lock;
- an unquiet capture, not reused when quiet is required;
- a `nextval` that writes no row, seen by the window fingerprint;
- a foreign staging database, refused;
- a busy source, refused;
- a finished bundle never overwritten;
- a resumed transfer;
- the second copy: an internal destination refused unless asked for, and refused for a bundle not on an external volume, on an external or unreported volume, in place of an absent drive, beside the bundle, inside a work tree, a stale worktree or a `.git` directory, and without its reserve;
- inputs bundled by their pins, and a damaged one refused;
- `restore` mode onto a cluster made by `dd.bootstrap.cluster`: same name, roles, exact state;
- the volume guard;
- the resumable copy;
- the doctor's verdicts, and that it is read-only.
