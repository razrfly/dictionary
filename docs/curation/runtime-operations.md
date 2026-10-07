# Curation runtime: operating the private model service

The runbook for stage A of [#195](https://github.com/razrfly/dictionary/issues/195). The
design is in [runtime-stage-a.md](runtime-stage-a.md), and the measurements in
[runtime-benchmark-2026-09-27.md](runtime-benchmark-2026-09-27.md).

Every command below is `mix dd.runtime …`. A command starts the repository and an HTTP
client, and nothing else: no Oban node, no endpoint. Point it at a database with
`DD_DATABASE`; with none set it uses the dev database. Use an isolated database until
the operator decides otherwise.

## Layout

Everything the runtime writes lives on the external volume. Source code and
PostgreSQL stay internal.

```
/Volumes/LLM Models/                  external volume (checked: mounted, Internal = false)
  dictionary/
    bin/ollama                        the runtime binary (and its libraries)
    downloads/                        the verified release archive
    ollama/                           OLLAMA_MODELS: manifests/ and blobs/
    run/ollama.pid, run/ollama.log    the one service's process id and log
    run/authority.json                which database's slot governs the service
    run/home/.ollama/                 the service's HOME: its signing key and cache
    run/tmp/                          the service's TMPDIR
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
                                  # the models root, binary or run directory is missing,
                                  # or something already listens on the port
mix dd.runtime service status     # %{pid, alive, listening}
mix dd.runtime service stop       # SIGTERM, then SIGKILL after 30 s; confirms the
                                  # process is gone and the port is closed. A pid
                                  # file whose pid no longer runs bin/ollama (after a
                                  # reboot) is stale: nothing is signalled, and the
                                  # stop is recorded as "not_running"
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

The benchmark of 2026-09-27 left the service bound to `devils_dictionary_runtime_bench`.

**Surviving a reboot.** `service start` does not survive a reboot or a logout. For
that, an operator can install a user LaunchAgent with the same program, arguments and
environment. It is not installed by this slice, and nothing here writes one. Such an
agent must:
- use the same pid file, so that `service stop` and `recover` can confirm the stop, or
  be unloaded with `launchctl bootout` before a recovery;
- keep the authority marker. launchd would not write it.

## Models (explicit setup; the only step that downloads)

```
mix dd.runtime setup --model qwen3.5:4b --slug qwen3.5-4b-v1 --pull
mix dd.runtime setup --model qwen3.5:4b --slug qwen3.5-4b-v1 --accept-license
```

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
mix dd.runtime packet  --lexeme 123 --out /path/packet.json
mix dd.runtime request --model-config qwen3.5-4b-v1 --packet /path/packet.json --key my-key-1
```

`packet` freezes the current, eligible registry evidence for the lexeme. `request`
runs the frozen packet once and prints the receipt. The same key replays the same
receipt. A request writes an attempt and its ledger entries. It never writes a
composition, review, publication, claim or page row.

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
2. stops the service and confirms it: the process is gone and the port is closed;
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

Only in a database whose name contains `bench` (`Bench.seed!/1` refuses otherwise):

```
DD_DATABASE=devils_dictionary_runtime_bench mix ecto.create
DD_DATABASE=devils_dictionary_runtime_bench mix ecto.migrate
DD_DATABASE=devils_dictionary_runtime_bench mix dd.runtime bench seed \
  --plan priv/curation/runtime_bench/plan.json --packets priv/curation/runtime_bench/packets
DD_DATABASE=devils_dictionary_runtime_bench mix dd.runtime bench run \
  --plan priv/curation/runtime_bench/plan.json --packets priv/curation/runtime_bench/packets \
  --out /path/bench.json
```

`bench seed` writes the frozen packets, and they are committed. Re-seeding a fresh
database gives new ids, so new packets and hashes; compare models only on the same
packet files. Every benchmark call goes through `Runtime.run/3`, and therefore counts
against the same daily budget.
