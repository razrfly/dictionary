#!/bin/zsh
# A fixed-deadline stop guard for a curation trial or comparison batch
# (#298 C6). launchd runs it every 60 seconds; see README.md.
#
#   trial-stop.sh --deadline EPOCH --run-dir DIR [--reason TEXT]
#                 [--checkout DIR] [--stop-script PATH] [--dry-run]
#
# Before EPOCH-60 it exits at once. In the last minute it sleeps to EPOCH,
# then, unless DIR/STOPPED exists, runs the stop script from the checkout
# with DD_NO_OBAN=1 and PHX_SERVER unset, appending to DIR/stop.log. If the
# stop fails it runs physical-stop.exs (beside the stop script) and exits 1;
# the next minute tries again.
#
# The deadline is bounded: whole seconds (at most 10 digits, so never
# milliseconds), at most 7 days ahead, and not stale. A deadline more than
# --grace-seconds (3600) in the past refuses with exit 65 and stops nothing,
# so a job loaded with an old epoch never stops a live system at load.
#
# --dry-run never runs the stop script, whatever --stop-script names. It
# runs the checkout's dry-run.exs, which proves this environment can start
# mix and reach the database read-only, hashes the stop script the real
# guard would run (reading it, not running it), writes DIR/DRY_RUN_OK and
# stops nothing. The deadline must then still be ahead.
set -eu

usage() {
  print -u2 "usage: trial-stop.sh --deadline EPOCH --run-dir DIR [--reason TEXT] [--checkout DIR] [--stop-script PATH] [--grace-seconds N] [--dry-run]"
  exit 64
}

deadline=''
run_dir=''
reason='fixed stop guard deadline reached'
checkout='/Volumes/LLM Models/dictionary/src/dictionary'
stop_script=''
grace=3600
dry_run=0
max_ahead=$(( 7 * 86400 ))

while (( $# > 0 )); do
  case $1 in
    --deadline) (( $# >= 2 )) || usage; deadline=$2; shift 2 ;;
    --run-dir) (( $# >= 2 )) || usage; run_dir=$2; shift 2 ;;
    --reason) (( $# >= 2 )) || usage; reason=$2; shift 2 ;;
    --checkout) (( $# >= 2 )) || usage; checkout=$2; shift 2 ;;
    --stop-script) (( $# >= 2 )) || usage; stop_script=$2; shift 2 ;;
    --grace-seconds) (( $# >= 2 )) || usage; grace=$2; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) usage ;;
  esac
done

[[ $deadline == <-> && ${#deadline} -le 10 ]] || usage
# Bound the digits before any arithmetic: zsh wraps a longer number to a
# negative one, which would pass `<= 86400` and make every tick stale.
[[ $grace == <-> && ${#grace} -le 5 ]] && (( grace <= 86400 )) || usage
[[ -n $run_dir ]] || usage
now=$(date +%s)

if (( deadline > now + max_ahead )); then
  print -u2 "deadline $deadline is more than 7 days ahead; refused, nothing stopped"
  exit 65
fi

if (( deadline + grace < now )); then
  print -u2 "deadline $deadline is stale (more than $grace s past); refused, nothing stopped"
  exit 65
fi

if (( dry_run && deadline <= now )); then
  print -u2 "a dry run needs a deadline still ahead; refused"
  exit 65
fi

if [[ ! -d $run_dir ]]; then
  print -u2 "run directory missing: $run_dir"
  exit 66
fi

if [[ ! -d $checkout ]]; then
  print -u2 "checkout missing: $checkout"
  exit 66
fi

[[ -n $stop_script ]] || stop_script="$checkout/ops/curation/trial-stop/stop.exs"
physical="${stop_script:h}/physical-stop.exs"
dry_script="$checkout/ops/curation/trial-stop/dry-run.exs"

if (( ! dry_run )); then
  if (( now < deadline - 60 )); then
    exit 0
  fi

  if (( now < deadline )); then
    sleep $(( deadline - now ))
  fi

  if [[ -f "$run_dir/STOPPED" ]]; then
    exit 0
  fi
fi

export PATH="/Applications/Postgres.app/Contents/Versions/18/bin:$HOME/.local/share/mise/shims:$PATH"
export DD_NO_OBAN=1
unset PHX_SERVER
mix_cmd=${DD_TRIAL_MIX:-mix}
cd "$checkout"

if (( dry_run )); then
  if [[ ! -r $stop_script ]]; then
    print -u2 "stop script not readable: $stop_script"
    exit 66
  fi

  "$mix_cmd" run --no-start "$dry_script" --run-dir "$run_dir" --stop-script "$stop_script" >> "$run_dir/stop.log" 2>&1
  exit $?
fi

if ! "$mix_cmd" run --no-start "$stop_script" --run-dir "$run_dir" --reason "$reason" >> "$run_dir/stop.log" 2>&1; then
  "$mix_cmd" run --no-start "$physical" >> "$run_dir/stop.log" 2>&1 || true
  exit 1
fi
