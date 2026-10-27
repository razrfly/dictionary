# Curation runtime: operating the private model service

The runbook for stage A of [#195](https://github.com/razrfly/dictionary/issues/195), and
for the operating window and rehearsals of
[#267](https://github.com/razrfly/dictionary/issues/267). The design is in
[runtime-stage-a.md](runtime-stage-a.md), and the measurements in
[runtime-benchmark-2026-09-27.md](runtime-benchmark-2026-09-27.md) and
[runtime-benchmark-2026-10-26-unlabelled.md](runtime-benchmark-2026-10-26-unlabelled.md).

Every command below is `mix dd.runtime …`. A command starts the repository and an HTTP
client, and nothing else: no Oban node, no endpoint. Point it at a database with
`DD_DATABASE`; with none set it uses the dev database. Use an isolated database until
the operator decides otherwise.

## Layout

Everything the runtime writes lives on the external volume. Since #211 the source
checkout and PostgreSQL (the cluster on port 5434) live there too; nothing of the
dictionary stays on the internal disk.

```
/Volumes/LLM Models/                  external volume (checked: mounted, Internal = false)
  dictionary/
    bin/ollama                        the runtime binary (and its libraries)
    downloads/                        the verified release archive
    ollama/                           OLLAMA_MODELS: manifests/ and blobs/
    run/ollama.pid, run/ollama.log    the one service's process id and log, during a window
    run/authority.json                which database's slot governs the service
    run/home/.ollama/                 the service's HOME: its signing key and cache
    run/tmp/                          the service's TMPDIR
    src/dictionary/                   the checkout (this runbook)
    postgres/                         the 5434 cluster
```

These paths are the `:curation_runtime` defaults in `config/config.exs`. They are
endpoint configuration, separate from any model config or persona.

## Install the runtime (once, by hand)

Installing is an operator's step. Nothing in the application downloads the runtime.

1. Check the volume is mounted and external:
   `diskutil info -plist "/Volumes/LLM Models"` must show `Internal` = `false`.
2. Download the official release archive into `downloads/`. Verify it against the
   release's `sha256sum.txt` before extracting. v0.34.4, `ollama-darwin.tgz`, is
   `e9c8fddaab5f48f47f2c4ae3d23d0732f5182417125353faeed2188e34a22799`.
3. Extract it into `bin/`. The archive is flat: `bin/ollama` plus its libraries.
   `codesign -dv bin/ollama` names Ollama's team, `3MU9H2V9Y9`.

The service does not need Ollama.app, and runs no system-wide agent.

## The service

```
mix dd.runtime service start      # refuses if the volume is not mounted and external,
                                  # a runner a dead server left is still alive (stop
                                  # first), the models root, binary or run directory is
                                  # missing, or something already listens on the port
mix dd.runtime service status     # %{pid, alive, listening}
mix dd.runtime service stop       # SIGTERM, then SIGKILL after 30 s; confirms the
                                  # process, every runner it started and any runner
                                  # a dead server left under launchd are gone, and the
                                  # port is closed. A server the pid file does not name
                                  # is never signalled. A pid file whose pid no longer
                                  # runs bin/ollama (after a reboot) is stale: it is not
                                  # signalled, and the stop is recorded as "not_running"
mix dd.runtime service restart
```

It runs one `ollama serve` on `127.0.0.1:11435`, never on another interface. It uses
a port other than Ollama's default, so it never collides with a personal install on
11434. Its environment:

| Variable | Value | Why |
|---|---|---|
| `OLLAMA_HOST` | `127.0.0.1:11435` | loopback only |
| `OLLAMA_MODELS` | `…/dictionary/ollama` | models on the external volume |
| `OLLAMA_MAX_LOADED_MODELS` | `1` | one model in memory; personas share it |
| `OLLAMA_NUM_PARALLEL` | `1` | defense in depth behind the slot |
| `OLLAMA_KEEP_ALIVE` | `10m` | a bounded warm window |
| `OLLAMA_NO_CLOUD` | `1` | no remote inference or web search; the log says `Ollama cloud disabled: true` |
| `HOME` | `…/dictionary/run/home` | otherwise Ollama writes `~/.ollama` on the internal disk at first start |
| `TMPDIR` | `…/dictionary/run/tmp` | any scratch file stays on the volume |

It runs from `run/`, not from a checkout. `start` downloads nothing.

**One database governs it.** The slot is a row in PostgreSQL, so callers must share a
database to share the slot. The first `service start` binds the service to the
database it is connected to, by writing `run/authority.json`: the database name, the
cluster's `system_identifier` and the service key. From then on:
- readiness refuses a caller of any other database with `foreign_authority`, before
  anything is sent;
- `service start` from another database refuses with `bound_to_other_database`;
- a missing marker is `authority_unbound`, and a damaged one `authority_unreadable`.

To move the binding, for example from a benchmark database to the real one:
1. check that the old database's slot holds no live attempt
   (`mix dd.runtime budget`, `sweep`, or the `inference_services` row);
2. stop the service;
3. run `mix dd.runtime service start --rebind` against the new database.

The benchmark of 2026-09-27 bound the service to `devils_dictionary_runtime_bench`, and it
stays bound there until #267's Delivery B. That delivery's step 2 runs `service start
--rebind` against `devils_dictionary_v2`, and records the marker's new contents (the
database and the cluster's `system_identifier`) on #267. After it:
- a benchmark opens a bench-bound window: it checks v2's slot is idle, stops the service,
  starts it with `--rebind` against the bench database, and at its end does the same back
  to v2;
- every benchmark and rehearsal record says which database the service was bound to.

To undo the rebind, stop the service and run `service start --rebind` against the bench
database: the marker names it again. Nothing else changes.

**Surviving a reboot.** `service start` does not survive a reboot or a logout. For
that, an operator can install a user LaunchAgent with the same program, arguments and
environment. It is not installed by this slice, and nothing here writes one. Such an
agent must:
- use the same pid file, so that `service stop` and `recover` can confirm the stop, or
  be unloaded with `launchctl bootout` before a recovery;
- keep the authority marker. launchd would not write it.

## Models (explicit setup; the only step that downloads)

```
mix dd.runtime setup --model qwen3.5:9b --slug qwen3.5-9b-v2 --pull
mix dd.runtime setup --model qwen3.5:9b --slug qwen3.5-9b-v2 \
  --instruction generic-editor-v2 --accept-license
```

`--instruction` names the pinned instruction the config runs (`Packet.instruction_versions/0`):
there is no default, because a config pins it and is immutable. The same model under a
new instruction is a new config with a new slug; `qwen3.5-9b-v1` runs `generic-editor-v1`
and `qwen3.5-9b-v2` runs `generic-editor-v2`.

`setup` checks the volume and the service. Before `--pull` it also checks that at
least `--min-free-gib` (default 20) is free on the volume. It prints the model's
license. Only `--accept-license` records the model config, and then only after the
operator has read the license. The record pins:
- the manifest digest, which must equal both the digest `/api/tags` serves and the
  sha256 of the manifest file under the models root;
- the layer, weights, license and template digests;
- the quantization, parameter size, family and format;
- the runtime version and capabilities;
- the generation settings (`num_ctx` 8192, `num_predict` 1024, temperature 0,
  seed 195, `think: false` for thinking-capable models, `keep_alive` 10m).

The same inputs give the same `config_hash`, so re-running is a no-op. A changed tag,
runtime or setting is a new config under a new slug. A config is never edited.

Readiness, requests and retries never download. A missing model is `model_missing`,
and a moved tag is `digest_mismatch`.

## Readiness and a first call

```
mix dd.runtime ready --model-config qwen3.5-4b-v1            # no model call
mix dd.runtime ready --model-config qwen3.5-4b-v1 --smoke    # plus one structured-output call
```

The checks, in order: slot, volume, models root, authority, runtime version, served
digest, manifest on the root. The stable refusals are:
- `quarantined`, `paused`;
- `models_root_unmounted`, `models_root_not_external`, `models_root_missing`;
- `authority_unbound`, `foreign_authority`, `authority_unreadable`;
- `service_unreachable`, `runtime_version_mismatch`;
- `model_missing`, `digest_mismatch`, `artifact_not_on_models_root`.

The smoke call goes through the same slot, budget and output validation, on a fixed
fictional packet.

## A request

```
mix dd.runtime packet  --model-config qwen3.5-4b-v1 --lexeme 123 --out /path/packet.json
mix dd.runtime request --model-config qwen3.5-4b-v1 --packet /path/packet.json --key my-key-1
```

`packet` freezes the current, eligible registry evidence for the lexeme, for the
config's instruction; `request` refuses a packet built for another one
(`instruction_version_mismatch`). `request`
runs the frozen packet once and prints the receipt. The same key replays the same
receipt. A request writes an attempt and its ledger entries. It never writes a
composition, review, publication, claim or page row.

## Rehearsal

A rehearsal runs one real page's packet once through the runtime, as an attempt only.
It is #267's "test against our actual database" before any proposal is written:

```
mix dd.runtime rehearse --model-config qwen3.5-9b-v2 --scope love --dry-run
mix dd.runtime rehearse --model-config qwen3.5-9b-v2 --scope love \
  --out priv/curation/runtime_bench/rehearsals/2026-11-03/love.json
```

`--dry-run` builds and freezes the packet the On page `love` offers, for the config's
pinned instruction. It prints it as `packet --scope love --dry-run` does, plus the request
key it would use. It calls nothing and writes nothing: no readiness, no row, no file.

Without `--dry-run`, `rehearse`:
1. refuses unless the service is bound to the connected database (`foreign_authority`,
   `authority_unbound`, `authority_unreadable`), and then touches nothing else;
2. builds and freezes the packet, as the dry run does;
3. refuses unless readiness passes (`service_unreachable`, `digest_mismatch`, …);
4. sends the frozen packet once through `Runtime.run/3`, as the operator's actor, under the
   request key `rehearsal:<config slug>:<packet hash>`, with the benchmark's readings:
   memory, swap and the loaded model before and after, and the service tree's peak
   resident set during the call.

It writes one JSON record, whether it ran, replayed or refused, and never over an existing
one. The default path is `priv/curation/runtime_bench/rehearsals/<UTC date>/<scope>.json`.
The record keeps:
- the database and the authority marker;
- the model config;
- the packet by ids, hashes and counts, with what was omitted and why;
- the readiness checks;
- the receipt;
- the validated answer: lead, highlights, reasons, refusals;
- latency, prompt and output tokens, memory and swap.

It keeps no excerpt or label text. It prints a summary:

```
database         devils_dictionary_v2
packet           10 of 32 candidates, 12 of 48 meanings, omitted 22 (reasons recorded)
attempt          2: accepted · lead c1 (bierce) · 2 highlights · 2.9 s · swap +0 MB
record           priv/curation/runtime_bench/rehearsals/2026-11-03/love.json
```

A rehearsal writes the attempt, its ledger entries and the record. It writes no
composition, review, publication, claim or refresh state, and it is not a page visit. The
same scope with unchanged inputs gives the same packet hash, so a second rehearsal
replays the first receipt: it sends nothing, and its record says `replay`. A changed
packet is a new request key and a new attempt.

## The operating window

The service runs only in a window the owner opens by hand. There is no LaunchAgent and no
schedule (#267 D-F). A window:
1. **Idle check.** Against the database the service is bound to: `budget`, `sweep` and the
   `inference_services` row show no holder and nothing live. Then `service status`: if it
   is running, `service stop` and keep its confirmation; if it is already stopped,
   `service stop` only confirms `not_running`.
2. **Start** the service bound to the database the work is for (`service start`, or
   `service start --rebind` when moving the binding).
3. **Work:** `ready --smoke`, then rehearsals. Once #264 is deployed and its editor
   enabled (#268 3c–3d), the editor runs on page visits during the window. Until then a
   visit never reaches an editor: on `main` the refresh worker only checks inputs
   (`Refresh.claim/3`, `Refresh.check/3`) and never calls the runtime.
4. **Stop and confirm:** `service stop`, its confirmation (server, runners, port), and the
   machine's memory and swap readings 30 s after.

The ops Health page (`/ops/health`) has an "Editor runtime" card. It shows:
- the slot's row;
- the database the marker names;
- the registered model configs;
- today's inference minutes;
- the last smoke and the last attempt.

It reads these with SELECTs and a file read, and starts, stops and calls nothing. It shows
current state only: a slot marked available is not proof that the process is running. A
window's start and stop are in its record.

### The first window on v2 (#267 Delivery B, #268 3a)

Each step runs on the owner's named yes, in this order. Without `DD_DATABASE`, a dev-env
task reaches `devils_dictionary_v2`:

```
$ DD_DATABASE=devils_dictionary_runtime_bench mix dd.runtime budget   # the old slot: no holder, nothing live
$ DD_DATABASE=devils_dictionary_runtime_bench mix dd.runtime sweep
$ mix dd.runtime service status                                # stopped: `service stop` then only confirms not_running
$ mix dd.runtime service start --rebind                        # authority → devils_dictionary_v2; record the marker
$ mix dd.runtime setup --model qwen3.5:9b --slug qwen3.5-9b-v2 \
      --instruction generic-editor-v2 --accept-license       # needs the running service; prints the license; no pull
$ mix dd.runtime ready --model-config qwen3.5-9b-v2 --smoke    # one attempt
$ mix dd.runtime rehearse --model-config qwen3.5-9b-v2 --scope love --dry-run
$ mix dd.runtime rehearse --model-config qwen3.5-9b-v2 --scope love
$ mix dd.runtime service stop                                  # confirmed; readings 30 s after
```

Run `rehearse` for war and hope the same way, each with `--dry-run` first. The step's
records:
- the marker's new contents;
- the config row's id and `config_hash`. It equals bench config 3's (`5b8b65ad…`) if the
  inputs are identical, and the record says why if not;
- the smoke receipt;
- the three rehearsal records;
- the confirmed stop and the readings after it.

v2 then holds one model config, one service row, four attempts (the smoke and three
rehearsals) and their ledger entries. It also holds one import actor, "Curation runtime
operator (CLI)", which `setup --accept-license` inserts on first use. That actor approves
nothing.

**Rollback:** `service stop`, then `service start --rebind` against the bench database,
which restores the previous marker. The v2 config row stays: it is immutable, harmless, and
history for the attempts that name it.

## The slot, the budget and recovery

```
mix dd.runtime budget [--day YYYY-MM-DD]     # charged, reserved, remaining (UTC day)
mix dd.runtime sweep                         # expired leases: admitted → released;
                                             # dispatched → uncertain, service quarantined
mix dd.runtime pause --reason TEXT
mix dd.runtime resume --model-config SLUG    # readiness first, then available
mix dd.runtime recover                       # a quarantined service, see below
```

**Quarantine** follows any call that was sent and not answered: a timeout, a closed
connection, a dead caller or an expired dispatched lease. None of these proves the
generation stopped, so the slot stays held and nothing is refunded. `recover`:
1. refuses, and stops nothing, unless this database is the bound one and its slot is
   quarantined (`foreign_authority`, `not_quarantined`);
2. stops the service and confirms it: the process and its runners are gone and the
   port is closed. The runner (`bin/llama-server`) holds the loaded weights, 6–8 GiB
   for 9B. One that outlived its server would be loaded again beside it on restart, so
   a runner that will not end is `runners_still_running`, and nothing is settled
   (#221 S1);
3. settles the uncertain attempt as `ended_by_restart`, charging its occupancy up to
   the confirmed stop, and bumps the service epoch;
4. starts the service again.

The service stays **paused** until `resume` passes readiness. A late answer from
before the restart is refused as stale.

**Pauses** also come from three runtime failures in a row, swap growth of 512 MB or
more during one call, or free memory under 10%. Check the machine before resuming.

## Stopping it after work

The service holds a loaded model in unified memory for up to `keep_alive` (10
minutes) after its last call. On a machine that is already swapping, stop the service
when no work is planned: `mix dd.runtime service stop`. The models stay on the volume.

## The benchmark

Only in a database whose name contains `bench` (`bench seed` and `bench run` refuse
otherwise). Every command below needs its `DD_DATABASE`: without it, a dev-env task
reaches `devils_dictionary_v2`.

```
DD_DATABASE=devils_dictionary_runtime_bench mix ecto.create
DD_DATABASE=devils_dictionary_runtime_bench mix ecto.migrate
DD_DATABASE=devils_dictionary_runtime_bench mix dd.runtime bench seed \
  --plan priv/curation/runtime_bench/plan-generic-editor-v2.json \
  --packets priv/curation/runtime_bench/packets-generic-editor-v2
DD_DATABASE=devils_dictionary_runtime_bench mix dd.runtime bench run \
  --plan priv/curation/runtime_bench/plan-generic-editor-v2.json \
  --packets priv/curation/runtime_bench/packets-generic-editor-v2 \
  --out /path/bench.json
```

`plan-generic-editor-v2-unlabelled.json` with `packets-generic-editor-v2-unlabelled/`
is the same plan with its ambiguous case rewritten so that its text does not announce
itself as fiction, plus a control case, `ambiguous_labelled`: v2's bank case under packet
v2, whose samples `Bench.verdict/5` leaves out of every go check. A case may name a source of its own (`fixture_source`),
because the model is shown each candidate's source slug. Its committed packets carry
`devils_dictionary_runtime_bench`'s ids, bank's v2 rows among them, so they run only
there; a fresh bench database must freeze new packets, which makes a new plan.

A plan names its `instruction_version`: `bench seed` freezes the packets for it, and
`bench run` skips a model whose config pins another. The report holds the samples, the
summary and the plan's go or no-go per model. September's `plan.json` names no
instruction: its committed packets can still be run, but not re-seeded.

`bench seed` writes the frozen packets, and they are committed. A packet file already in
`--packets` is the plan's: `bench seed` keeps it while it still verifies against the
database and names the plan's instruction, and otherwise raises ("never re-frozen in
place") without touching it (#262). So re-seeding the database the packets came from
changes nothing, and a fresh database, whose ids differ, cannot verify them: remove the
files first to freeze new packets there, which this build writes as `runtime-packet-v2`,
with new hashes. Compare models only on the same packet files. Every benchmark call goes
through `Runtime.run/3`, and therefore counts against the same daily budget.
