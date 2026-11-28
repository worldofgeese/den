#!/usr/bin/env bash
# Exercise guix/container-updater.sh against stub podman, herd and sleep, so no
# live container, image or shepherd service is touched.
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/guix/container-updater.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
home=$tmp/home
mkdir -p "$tmp/bin" "$home/.agents/memory"
echo db > "$home/.agents/memory/memories.db"
for i in 1 2 3; do
  mkdir "$home/.agents/memory.bak-old$i-2020"
  touch -d "2020-01-0$i" "$home/.agents/memory.bak-old$i-2020"
done

cat > "$tmp/bin/podman" <<'EOF'
#!/bin/sh
echo "podman $*" >> "$HOME/calls"
case "$1 $2" in
  "pull --quiet") case "$3" in *bad*) exit 1 ;; esac ;;
  "inspect -f") case "$4" in same) echo sameid ;; *) echo oldid1234567890abc ;; esac ;;
  "image inspect") case "$5" in *same*) echo sameid ;; *) echo newid0987654321xyz ;; esac ;;
esac
EOF
cat > "$tmp/bin/herd" <<'EOF'
#!/bin/sh
echo "herd $*" >> "$HOME/calls"
if [ "$1" = status ]; then
  if [ "$2" = stopped ]; then echo "It is stopped."; else echo "It is running since now"; fi
fi
EOF
# First sleep (the start-up delay) returns; the second ends the loop.
cat > "$tmp/bin/sleep" <<'EOF'
#!/bin/sh
n=$(cat "$HOME/sleeps" 2>/dev/null || echo 0)
echo $((n + 1)) > "$HOME/sleeps"
[ "$n" -ge 1 ] && kill "$PPID"
exit 0
EOF
chmod +x "$tmp/bin/"*

HOME=$home PATH=$tmp/bin:$PATH sh "$script" \
  headroom headroom img/headroom:latest \
  signet signet img/signet:latest \
  bad bad img/bad:latest \
  stopped stopped img/stopped:latest \
  same same img/same:latest > "$tmp/log" 2>&1 || true

fail=0
check() { # description, command...
  local what=$1; shift
  if "$@"; then echo "PASS: $what"; else echo "FAIL: $what"; fail=1; fi
}
calls=$home/calls
check "changed running service is restarted" grep -qx 'herd restart headroom' "$calls"
check "signet is stopped, snapshotted, then started" \
  bash -c "grep -A1 -x 'herd stop signet' '$calls' | grep -qx 'herd start signet'"
check "signet snapshot taken" test -f "$home/.agents/memory.bak-oldid1234567-$(date +%F)/memories.db"
check "only three snapshots kept" test "$(find "$home/.agents" -maxdepth 1 -name 'memory.bak-*' | wc -l)" -eq 3
check "oldest snapshot removed" test ! -e "$home/.agents/memory.bak-old1-2020"
check "failed pull does not stop the loop" grep -q 'img/same:latest' "$calls"
check "stopped service is not started" bash -c "! grep -Eq 'herd (re)?start stopped' '$calls'"
check "up-to-date service is not restarted" bash -c "! grep -Eq 'herd (restart|stop) same' '$calls'"
check "dangling images pruned" grep -qx 'podman image prune -f' "$calls"
check "stamp written" test -f "$home/.local/state/container-updater.stamp"

[ "$fail" -eq 0 ] || { cat "$tmp/log"; exit 1; }
