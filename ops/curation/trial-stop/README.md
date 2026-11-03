# Trial stop guard (#298 C6)

A fixed-deadline stop for a curation trial window or a comparison batch, run by
launchd every 60 seconds. It is the v6 and v7 guards with the deadline, run
directory, reason and stop script as arguments instead of edited copies.
Loading, unloading and the dry run are live steps: each needs the owner's yes.

| File | What it is |
|---|---|
| `trial-stop.sh` | The guard launchd runs. Exits at once before `deadline - 60`; in the last minute sleeps to the deadline; then, unless `RUN_DIR/STOPPED` exists, runs the stop script from the serving checkout with `DD_NO_OBAN=1` and `PHX_SERVER` unset, appending to `RUN_DIR/stop.log`. If the stop fails it runs `physical-stop.exs` and exits 1. |
| `stop.exs` | The stop: disable the editor (already disabled, as in a comparison batch, is fine), pause the gateway, stop the private model service, prove the editor is off and the port closed, write `RUN_DIR/STOPPED`. Refuses any target but `devils_dictionary_v2` on 5434 in cluster `7693849764459364596`. |
| `physical-stop.exs` | The fallback: stop the private model service only, and prove it. |
| `io.wordhoard.trial-stop.plist.template` | The launchd job, with placeholders. |
| `render-plist.sh` | Prints the plist for given arguments. Loads nothing. |

`trial-stop.sh` arguments: `--deadline EPOCH` (UTC seconds), `--run-dir DIR`
(must exist), `--reason TEXT`, `--checkout DIR` (default the serving checkout),
`--stop-script PATH` (default `CHECKOUT/ops/curation/trial-stop/stop.exs`; name a
frozen copy in the run directory to pin it), `--dry-run`. The deadline never
moves: a new deadline is a new job.

## The dry run: can launchd start `mix` here?

`--dry-run` ignores the deadline and `STOPPED`, and runs `stop.exs --dry-run`:
it starts `mix` in launchd's environment, connects read-only, checks the target
and cluster, reads the editor switch and the service status, writes
`RUN_DIR/DRY_RUN_OK` with what it found, and stops nothing.

```sh
GUARD="$HOME/Library/Application Support/DictionaryTrial"
mkdir -p "$GUARD"
install -m 0755 ops/curation/trial-stop/trial-stop.sh "$GUARD/trial-stop.sh"
RUN="/Volumes/LLM Models/dictionary/run/d6-2026-11-04"
ops/curation/trial-stop/render-plist.sh --label io.wordhoard.d6-stop-dry-run \
  --script "$GUARD/trial-stop.sh" --deadline 1793800000 --run-dir "$RUN" \
  --log "$GUARD/d6-stop-dry-run.log" --dry-run \
  > "$HOME/Library/LaunchAgents/io.wordhoard.d6-stop-dry-run.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/io.wordhoard.d6-stop-dry-run.plist"
# RunAtLoad runs it once at load. Then:
cat "$RUN/DRY_RUN_OK"; tail "$RUN/stop.log"
launchctl bootout "gui/$(id -u)/io.wordhoard.d6-stop-dry-run"
rm "$HOME/Library/LaunchAgents/io.wordhoard.d6-stop-dry-run.plist"
```

Unload the dry-run job straight after its first run: it runs every 60 seconds
while loaded.

## Load the real guard

Render without `--dry-run`, under its own label, with the batch's or window's
deadline (`date -j -u -f "%Y-%m-%dT%H:%M:%SZ" 2026-11-04T12:00:00Z +%s` gives the
epoch):

```sh
ops/curation/trial-stop/render-plist.sh --label io.wordhoard.d6-stop \
  --script "$GUARD/trial-stop.sh" --deadline EPOCH --run-dir "$RUN" \
  --log "$GUARD/d6-stop.log" --reason "D6 batch: fixed stop" \
  > "$HOME/Library/LaunchAgents/io.wordhoard.d6-stop.plist"
plutil -lint "$HOME/Library/LaunchAgents/io.wordhoard.d6-stop.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/io.wordhoard.d6-stop.plist"
launchctl print "gui/$(id -u)/io.wordhoard.d6-stop" | grep -E 'state|runs|last exit'
```

Verify it is loaded and exits 0 every minute (`runs` grows, `last exit code = 0`).

## After the deadline

`RUN_DIR/STOPPED` holds the stop time and `stop.log` ends with `STOP VERIFIED`.
Record the stopped state (private service not listening, editor disabled, last
attempt id, charged budget), then unload:

```sh
launchctl bootout "gui/$(id -u)/io.wordhoard.d6-stop"
rm "$HOME/Library/LaunchAgents/io.wordhoard.d6-stop.plist"
```

A loaded guard whose `STOPPED` exists only exits early; unloading it is tidy-up,
not part of the stop. If `STOPPED` is absent two minutes after the deadline,
the guard failed: run `stop.exs` by hand on the owner's yes and record it.
