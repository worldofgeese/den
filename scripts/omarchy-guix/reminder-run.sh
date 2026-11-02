# Reminder timers without systemd-run.
#   reminder-run STATE SECONDS CMD...   run CMD after SECONDS, detached
#   reminder-run --list                 "UNIT.timer<TAB>DUE_USEC" per pending reminder
#   reminder-run --clear                cancel every pending reminder
# STATE.at holds the due time and STATE.pid the sleeper's process group.
set -euo pipefail
dir="${XDG_RUNTIME_DIR:-/tmp}/omarchy-reminders"
case ${1:-} in
  --list)
    for f in "$dir"/omarchy-reminder-*.at; do
      [[ -f $f ]] || continue
      unit=${f##*/}
      printf '%s.timer\t%s\n' "${unit%.at}" "$(($(<"$f") * 1000000))"
    done
    exit 0
    ;;
  --clear)
    for f in "$dir"/omarchy-reminder-*.pid; do
      [[ -f $f ]] || continue
      kill -- "-$(<"$f")" 2>/dev/null || true
      rm -f "$f" "${f%.pid}.at"
    done
    exit 0
    ;;
esac
state=$1
seconds=$2
shift 2
mkdir -p "${state%/*}"
printf '%s\n' "$(($(date +%s) + seconds))" >"$state.at"
exec @setsid@ --fork bash -c \
  'echo $$ >"$1.pid"; sleep "$2"; rm -f "$1.at" "$1.pid"; shift 2; exec "$@"' \
  _ "$state" "$seconds" "$@" </dev/null >/dev/null 2>&1
