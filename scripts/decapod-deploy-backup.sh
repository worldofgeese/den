#!/usr/bin/env bash
# Run by `just deploy-darwin` inside the switch lock, just before
# darwin-rebuild. Makes a copy of the shared Decapod store when the deploy
# changes Decapod. Tested by scripts/test-decapod-deploy-backup.sh.
#
# Decapod moves forward with no hold: the nightly bump moves the `decapod`
# flake input, and topgrade deploys it (owner decision, 2026-11-09). A new
# Decapod can migrate .decapod/data/decapod.db at its first command, and all
# agents on this machine share that one store. The copy is the rollback point
# for that change. Only the owner restores a copy ("Decapod store copies" in
# .decapod/managed/specs/OPERATIONS.md).
#
# "Changes Decapod" means: the decapod package that this checkout installs for
# dktaohan is not on the symlink path of the installed decapod. So a new
# release, a new unreleased commit and a new package build all count.
#
# The copy uses SQLite's online backup and opens the store read-only, so the
# copy is consistent while agents write. The copy must pass
# `PRAGMA integrity_check` and have pages. The newest 5 copies stay in
# ~/.local/state/den-decapod-backups.
#
# The deploy stops when the evaluation fails or takes more than 30 minutes,
# when it finds no decapod package or more than one, and when the copy or its
# check fails. A failed copy is removed. To deploy without the copy on purpose, for
# example when the store itself is broken, set DEN_SKIP_DECAPOD_BACKUP=1.
set -euo pipefail

host=M-02877
user=dktaohan
keep=5

fail() {
  printf 'decapod-deploy-backup: %s\n' "$@" >&2
  echo "To deploy without the copy on purpose, run: DEN_SKIP_DECAPOD_BACKUP=1 just deploy-darwin" >&2
  exit 1
}

if [[ -n "${DEN_SKIP_DECAPOD_BACKUP:-}" ]]; then
  echo "decapod-deploy-backup: DEN_SKIP_DECAPOD_BACKUP is set; no copy is made" >&2
  exit 0
fi

common="$(git rev-parse --path-format=absolute --git-common-dir)"
db="$(dirname "$common")/.decapod/data/decapod.db"
if [[ ! -f "$db" ]]; then
  echo "decapod-deploy-backup: no shared store at $db; no copy is made" >&2
  exit 0
fi

# The decapod package that this checkout installs (Home Manager's pkgs, where
# the overlay in modules/overlays.nix applies). The timeout keeps a hung
# evaluation from holding the switch lock. It is long because the evaluation
# also fetches the flake inputs that the nightly bump changed, and the Wi-Fi
# here can be slow. macOS has no `timeout`; it comes from GNU coreutils.
command -v timeout >/dev/null ||
  fail "timeout (GNU coreutils) is not on PATH; it limits the evaluation to 30 minutes."
if ! new="$(timeout 1800 nix eval --option warn-dirty false --raw \
  ".#darwinConfigurations.$host.config.home-manager.users.$user.home.packages" \
  --apply 'ps: builtins.concatStringsSep " " (map (p: p.outPath)
    (builtins.filter (p: (builtins.parseDrvName (p.name or "")).name == "decapod") ps))')"; then
  fail "cannot evaluate the home packages of $user on $host in 30 minutes (see the error above)."
fi
if [[ -z "$new" || "$new" == *" "* ]]; then
  fail "the home packages of $user on $host must hold one package named decapod, not: ${new:-none}." \
    "If a change renamed it, update the filter in scripts/decapod-deploy-backup.sh."
fi

# Every store path on the symlink path of the installed decapod.
link="/etc/profiles/per-user/$user/bin/decapod"
chain=""
while [[ -L "$link" ]]; do
  target="$(readlink "$link")"
  [[ "$target" == /* ]] || target="$(dirname "$link")/$target"
  chain+=" $target"
  link="$target"
done
if [[ "$chain " == *" $new/"* ]]; then
  exit 0
fi

name() {
  local path="${1#/nix/store/}"
  echo "${path#*-}"
}
installed="$(readlink -f "/etc/profiles/per-user/$user/bin/decapod" 2>/dev/null || true)"
from="$(name "${installed%%/bin/*}")"
dir="${XDG_STATE_HOME:-$HOME/.local/state}/den-decapod-backups"
dest="$dir/$(date -u +%Y%m%dT%H%M%SZ)-${from:-none}-to-$(name "$new").db"
# The copy holds the whole store, so only the user may read it.
umask 077
mkdir -p "$dir"
# A copy is complete only after the mv below. Remove the partial file of this
# run on any exit, and the partial files of runs that were killed.
trap 'rm -f -- "$dest.partial"' EXIT
rm -f -- "$dir"/*.partial

echo "decapod-deploy-backup: this deploy changes decapod (${from:-none} -> $(name "$new")); copying $db"
if ! sqlite3 -readonly -cmd '.timeout 10000' "$db" ".backup '$dest.partial'"; then
  fail "the SQLite backup of $db failed (see the error above)." \
    "Check the store with 'decapod data database verify' from a Decapod workspace."
fi
# An empty database also passes integrity_check, so the copy needs pages too.
check="$(sqlite3 -readonly "$dest.partial" 'PRAGMA integrity_check;' 2>&1 || true)"
pages="$(sqlite3 -readonly "$dest.partial" 'PRAGMA page_count;' 2>/dev/null || echo 0)"
if [[ "$check" != ok || -z "$pages" || "$pages" == 0 ]]; then
  fail "the copy of $db fails PRAGMA integrity_check or is empty ($pages pages), so it is removed:" \
    "$(printf '%s\n' "$check" | head -5)" \
    "Check the store with 'decapod data database verify' from a Decapod workspace."
fi
mv "$dest.partial" "$dest"
echo "decapod-deploy-backup: copy $dest ($(du -h "$dest" | cut -f1 | tr -d ' '))"

# Names start with a UTC time stamp, so the glob sorts the oldest first.
shopt -s nullglob
copies=("$dir"/*.db)
if ((${#copies[@]} > keep)); then
  rm -f -- "${copies[@]:0:${#copies[@]}-keep}"
fi
