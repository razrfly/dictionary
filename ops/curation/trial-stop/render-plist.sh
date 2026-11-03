#!/bin/zsh
# Prints a launchd plist for trial-stop.sh from the template beside it
# (#298 C6). It loads, writes and starts nothing.
#
#   render-plist.sh --label io.wordhoard.NAME --script PATH --deadline EPOCH \
#     --run-dir DIR --log PATH [--reason TEXT] [--stop-script PATH] [--dry-run]
set -eu

usage() {
  print -u2 "usage: render-plist.sh --label io.wordhoard.NAME --script PATH --deadline EPOCH --run-dir DIR --log PATH [--reason TEXT] [--stop-script PATH] [--dry-run]"
  exit 64
}

label='' script='' deadline='' run_dir='' log='' stop_script='' dry_run=0
reason='fixed stop guard deadline reached'

while (( $# > 0 )); do
  case $1 in
    --label) (( $# >= 2 )) || usage; label=$2; shift 2 ;;
    --script) (( $# >= 2 )) || usage; script=$2; shift 2 ;;
    --deadline) (( $# >= 2 )) || usage; deadline=$2; shift 2 ;;
    --run-dir) (( $# >= 2 )) || usage; run_dir=$2; shift 2 ;;
    --log) (( $# >= 2 )) || usage; log=$2; shift 2 ;;
    --reason) (( $# >= 2 )) || usage; reason=$2; shift 2 ;;
    --stop-script) (( $# >= 2 )) || usage; stop_script=$2; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) usage ;;
  esac
done

[[ $label =~ '^io\.wordhoard\.[a-z0-9][a-z0-9.-]*$' ]] || usage
[[ $deadline == <-> ]] || usage
for p in $script $run_dir $log; do [[ $p == /* ]] || usage; done
[[ -z $stop_script || $stop_script == /* ]] || usage

xml() {
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  print -rn -- "$s"
}

extra=''
if [[ -n $stop_script ]]; then
  extra+=$'\t\t<string>--stop-script</string>\n'
  extra+=$'\t\t<string>'"$(xml "$stop_script")"$'</string>\n'
fi
if (( dry_run )); then
  extra+=$'\t\t<string>--dry-run</string>\n'
fi

template=$(<"${0:A:h}/io.wordhoard.trial-stop.plist.template")
out=${template//__LABEL__/$(xml "$label")}
out=${out//__SCRIPT__/$(xml "$script")}
out=${out//__DEADLINE__/$deadline}
out=${out//__RUN_DIR__/$(xml "$run_dir")}
out=${out//__REASON__/$(xml "$reason")}
out=${out//__LOG__/$(xml "$log")}
out=${out//__EXTRA__/$extra}
print -r -- "$out"
