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
# stop fails it runs physical-stop.exs (beside the stop script) and exits 1.
#
# --dry-run ignores the deadline and STOPPED, and runs the stop script with
# --dry-run: it proves this environment can start mix and reach the
# database, writes DIR/DRY_RUN_OK, and stops nothing.
set -eu

usage() {
  print -u2 "usage: trial-stop.sh --deadline EPOCH --run-dir DIR [--reason TEXT] [--checkout DIR] [--stop-script PATH] [--dry-run]"
  exit 64
}

deadline=''
run_dir=''
reason='fixed stop guard deadline reached'
checkout='/Volumes/LLM Models/dictionary/src/dictionary'
stop_script=''
dry_run=0

while (( $# > 0 )); do
  case $1 in
    --deadline) (( $# >= 2 )) || usage; deadline=$2; shift 2 ;;
    --run-dir) (( $# >= 2 )) || usage; run_dir=$2; shift 2 ;;
    --reason) (( $# >= 2 )) || usage; reason=$2; shift 2 ;;
    --checkout) (( $# >= 2 )) || usage; checkout=$2; shift 2 ;;
    --stop-script) (( $# >= 2 )) || usage; stop_script=$2; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) usage ;;
  esac
done

[[ $deadline == <-> ]] || usage
[[ -n $run_dir ]] || usage

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

if (( ! dry_run )); then
  now=$(date +%s)

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
  "$mix_cmd" run --no-start "$stop_script" --dry-run --run-dir "$run_dir" >> "$run_dir/stop.log" 2>&1
  exit $?
fi

if ! "$mix_cmd" run --no-start "$stop_script" --run-dir "$run_dir" --reason "$reason" >> "$run_dir/stop.log" 2>&1; then
  "$mix_cmd" run --no-start "$physical" >> "$run_dir/stop.log" 2>&1 || true
  exit 1
fi
