#!/bin/sh
# Keep the Guix Home containers on their :latest images.
#
# Usage: container-updater.sh SERVICE CONTAINER IMAGE [SERVICE CONTAINER IMAGE ...]
#
# Runs forever as a shepherd service (see container-updater in
# home-configuration.scm). Once a day, for each entry: pull IMAGE, and if the
# running CONTAINER is on an older image id, restart the shepherd SERVICE that
# owns it -- but only when that service is running, so a service the user
# stopped stays stopped. Signet's memory directory is snapshotted first,
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
  if [ "$service" = signet ]; then
    # Stop first so the snapshot is not taken from a live SQLite database.
    herd stop "$service"
    snapshot_memory "$old" || return 0
    herd start "$service" || log "$service: start FAILED"
  else
    herd restart "$service" || log "$service: restart FAILED"
  fi
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
