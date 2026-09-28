#!/usr/bin/env bash
# Run by `just deploy-darwin` before darwin-rebuild, so before nix-darwin's
# `brew bundle`. Checks every installed cask's app bundles for three states that
# make a cask upgrade fail:
#
# 0. An appdir this user cannot write. This user is not in the admin group, so
#    /Applications (root:admin, 775) is read-only to them, but casks installed
#    while they briefly had admin rights are recorded there. Homebrew's upgrade
#    empties the bundle, then cannot remove the directory, then tries sudo and
#    is refused. The result is an empty ChatGPT.app in /Applications and an
#    empty backup in the Caskroom. So before that can happen, every such cask
#    that is outdated, or whose app is already an empty shell, is reinstalled
#    into $target_appdir (the configured homebrew.caskArgs.appdir). The old
#    copy in the unwritable appdir is left untouched, and the admin command to
#    remove it is printed.
#
# 1. Root-owned files inside the app. Self-updaters (Squirrel ShipIt, Sparkle,
#    JetBrains) leave these in /Applications. Homebrew then cannot move the
#    app aside, and its sudo chown is refused, because this user may not use
#    sudo. Worse, the failed upgrade can delete part of the app first: that is
#    how ChatGPT.app lost its binary. This script stops the deploy and prints
#    the single admin command that fixes it (ownership only; nothing is
#    deleted). Only the app in the cask's recorded appdir is checked.
# 2. A leftover backup copy in the Caskroom from an earlier failed upgrade
#    ("It seems there is already an App at .../Caskroom/..."). When the live app
#    is present it is moved to the Trash, which can be undone.
#
# Exit 0 when the upgrade can proceed; 1 when admin action is needed.
set -euo pipefail

command -v brew >/dev/null || exit 0
caskroom="$(brew --prefix)/Caskroom"
# Must match homebrew.caskArgs.appdir in modules/M-02877/darwin.nix.
target_appdir="$HOME/Applications"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/cask-app-preflight"

# Refresh the API first: activation's `brew bundle` updates before it
# upgrades, so a stale view here would miss the upgrades that do the damage.
brew update --quiet >/dev/null 2>&1 || true
# --greedy: `brew bundle` also upgrades auto_updates casks such as chatgpt.
outdated="$(brew outdated --cask --greedy --quiet 2>/dev/null || true)"
is_outdated() { grep -qxF "$1" <<<"$outdated"; }

rows="$(brew info --cask --installed --json=v2 2>/dev/null | jq -r '
  .casks[] | .token as $t | (.installed // "") as $v
  | .artifacts[]? | select(has("app")) | .app[] | strings
  | [$t, $v, .] | @tsv')"

# Reinstall a cask into $target_appdir. Its Caskroom record is parked first so
# Homebrew forgets the unwritable appdir and never tries to delete the old app;
# on failure the record is put back and the old app is still intact.
migrate() {
  local token="$1" parked
  mkdir -p "$state_dir"
  parked="$state_dir/$token-caskroom-$(date +%Y%m%d%H%M%S)"
  mv "$caskroom/$token" "$parked" || return 1
  # </dev/null: the caller's read loop owns stdin.
  if brew install --cask --force --appdir="$target_appdir" "$token" </dev/null; then
    rm -rf "$parked"
    return 0
  fi
  rm -rf "${caskroom:?}/$token"
  mv "$parked" "$caskroom/$token"
  return 1
}

root_owned=()
migrated=()
failed=()
stale=()
seen=" "
while IFS=$'\t' read -r token version app; do
  [ -n "$token" ] || continue
  # Only the directory the cask was installed into matters: Homebrew records it
  # per cask and never touches copies elsewhere. On M-02877 the device
  # management (Jamf) installs its own, SIP-protected copies of some apps in
  # /Applications, and even root cannot chown those.
  appdir="$(jq -r '(.explicit.appdir // .default.appdir) // empty' \
    "$caskroom/$token/.metadata/config.json" 2>/dev/null || true)"
  appdir="${appdir:-/Applications}"
  live="$appdir/$app"
  [ -e "$live" ] || live=""
  if [ ! -w "$appdir" ]; then
    # A cask can list several apps; decide once per cask.
    case "$seen" in *" $token "*) continue ;; esac
    seen+="$token "
    gutted=""
    [ -n "$live" ] && [ ! -e "$live/Contents/Info.plist" ] && gutted=1
    if is_outdated "$token" || [ -n "$gutted" ]; then
      echo "cask-app-preflight: $appdir is not writable; moving $token to $target_appdir"
      if migrate "$token"; then
        migrated+=("$token")
        [ -z "$live" ] || stale+=("$live")
      else
        failed+=("$token")
      fi
    fi
    continue
  fi
  if [ -n "$live" ] && [ -n "$(find "$live" ! -user "$USER" -print -quit 2>/dev/null)" ]; then
    root_owned+=("$live")
  fi
  backup="$caskroom/$token/$version/$app"
  if [ -n "$live" ] && [ -d "$backup" ] && [ ! -L "$backup" ]; then
    dest="$HOME/.Trash/$token-caskroom-backup-$(date +%Y%m%d%H%M%S).app"
    mv "$backup" "$dest"
    echo "cask-app-preflight: moved stale Caskroom backup of $token to $dest"
  fi
done <<<"$rows"

if [ "${#stale[@]}" -gt 0 ]; then
  printf 'cask-app-preflight: moved %s to %s. The old copies are unused but only\n' "${migrated[*]}" "$target_appdir" >&2
  printf 'an admin can delete them (optional; nothing breaks if you leave them):\n' >&2
  paths=""
  for p in "${stale[@]}"; do paths+=" \\\"$p\\\""; done
  printf "  osascript -e 'do shell script \"rm -rf%s\" with administrator privileges'\n\n" "$paths" >&2
fi
if [ "${#failed[@]}" -gt 0 ]; then
  printf 'cask-app-preflight: could not reinstall %s into %s; their upgrade would\n' "${failed[*]}" "$target_appdir" >&2
  printf 'empty the app, so the deploy stops. Old installs are unchanged.\n' >&2
  exit 1
fi

[ "${#root_owned[@]}" -eq 0 ] && exit 0

printf 'cask-app-preflight: these apps contain files not owned by %s, so a\n' "$USER" >&2
printf 'Homebrew upgrade would fail and could leave them half-deleted:\n' >&2
printf '  %s\n' "${root_owned[@]}" >&2
# App bundle names contain spaces but never quotes, so each path is wrapped in
# AppleScript-escaped double quotes inside a single-quoted shell argument.
paths=""
for p in "${root_owned[@]}"; do paths+=" \\\"$p\\\""; done
printf '\nFix (one password dialog; changes ownership only), then re-run the deploy:\n' >&2
printf "  osascript -e 'do shell script \"chown -R %s:admin%s\" with administrator privileges'\n" "$USER" "$paths" >&2
exit 1
