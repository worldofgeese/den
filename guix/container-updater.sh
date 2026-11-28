#!/bin/sh
# Keep the Guix Home containers on their :latest images.
#
# Usage: container-updater.sh SERVICE CONTAINER IMAGE [SERVICE CONTAINER IMAGE ...]
#
# Runs forever as a shepherd service (see container-updater in
# home-configuration.scm). Once a day, for each entry: pull IMAGE, and if the
# running CONTAINER is on an older image id, restart CONTAINER and the shepherd
# SERVICE that owns it -- but only when that service is running, so a service
# the user stopped stays stopped. Signet's memory directory is snapshotted first,
# because a new signet may migrate memories.db with no way back.
#
# A wall-clock stamp file, not `sleep 86400`: sleep does not count time spent
# suspended, so on a laptop a plain day-long sleep may never finish.

stamp="$HOME/.local/state/container-updater.stamp"
memory="$HOME/.agents/memory"

log() { printf '%s container-updater: %s\n' "$(date '+%F %T')" "$*"; }

snapshot_memory() {
  # $1: short id of the image signet is leaving.
  [ -d "$memory" ] || return 0
  dest="$memory.bak-$1-$(date +%F)"
  if [ -e "$dest" ]; then
    log "snapshot $dest already exists"
  elif cp -a "$memory" "$dest"; then
    log "snapshot $dest"
  else
    log "snapshot $dest FAILED; leaving signet stopped rather than migrate unbacked"
    rm -rf "$dest"
    return 1
  fi
  # Keep the three newest snapshots. ls -t is the portable mtime sort; the
  # names are ours (memory.bak-<id>-<date>), so no odd characters.
  # shellcheck disable=SC2012
  ls -1dt "$memory".bak-* 2>/dev/null | tail -n +4 | while IFS= read -r old; do
    log "removing old snapshot $old"
    rm -rf "$old"
  done
}

wait_stopped() {
  # $1: service. Wait at most 30 s until shepherd no longer reports it running.
  n=0
  while herd status "$1" 2>/dev/null | grep -q 'It is running'; do
    [ "$n" -ge 30 ] && return 1
    sleep 1
    n=$((n + 1))
  done
}

update_one() {
  service=$1 container=$2 image=$3
  if ! podman pull --quiet "$image" >/dev/null; then
    log "$service: pull of $image failed; will retry next run"
    return 0
  fi
  running=$(podman inspect -f '{{.Image}}' "$container" 2>/dev/null)
  latest=$(podman image inspect -f '{{.Id}}' "$image" 2>/dev/null)
  if [ -z "$running" ] || [ -z "$latest" ] || [ "$running" = "$latest" ]; then
    log "$service: up to date (${latest:-unknown})"
    return 0
  fi
  if ! herd status "$service" 2>/dev/null | grep -q 'It is running'; then
    log "$service: $image has a new image but the service is not running; leaving it"
    return 0
  fi
  old=$(printf '%.12s' "$running")
  log "$service: $old -> $(printf '%.12s' "$latest"), restarting"
  # Do not use `herd stop` or `herd restart` here. On an OCI service they fail
  # with "setsid: Operation not permitted" (guix issue #12581, fix in guix PR
  # #12601). Stop the container with podman instead. Shepherd sees the
  # `podman run` process stop and marks the service stopped. If shepherd
  # respawns it, that is harmless: `podman run --replace` uses the new :latest
  # image. Go back to `herd restart` when the pinned guix has that fix.
  if ! podman stop -t 30 "$container" >/dev/null; then
    log "$service: podman stop FAILED"
    return 0
  fi
  if ! wait_stopped "$service"; then
    log "$service: still running 30 s after podman stop"
    if [ "$service" = signet ]; then
      log "$service: no snapshot from a live database; leaving it"
      return 0
    fi
  fi
  if [ "$service" = signet ]; then
    # Snapshot after the stop, so it is not taken from a live SQLite database.
    snapshot_memory "$old" || return 0
  fi
  herd start "$service" >/dev/null || log "$service: start FAILED"
}

run_all() {
  while [ $# -ge 3 ]; do
    update_one "$1" "$2" "$3"
    shift 3
  done
  podman image prune -f >/dev/null || log "image prune failed"
  mkdir -p "$(dirname "$stamp")" && touch "$stamp"
}

# Let login settle and the oci-images pull finish before the first check.
sleep 600
while :; do
  if [ -z "$(find "$stamp" -mmin -1440 2>/dev/null)" ]; then
    log "checking $(($# / 3)) container(s)"
    run_all "$@"
  fi
  sleep 3600
done
