#!/usr/bin/env bash
# Run by `just deploy-darwin` before darwin-rebuild, so before nix-darwin's
# `brew bundle`. Checks every installed cask's app bundles for two states that
# make a cask upgrade fail:
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

rows="$(brew info --cask --installed --json=v2 2>/dev/null | jq -r '
  .casks[] | .token as $t | (.installed // "") as $v
  | .artifacts[]? | select(has("app")) | .app[] | strings
  | [$t, $v, .] | @tsv')"

root_owned=()
while IFS=$'\t' read -r token version app; do
  [ -n "$token" ] || continue
  # Only the directory the cask was installed into matters: Homebrew records it
  # per cask and never touches copies elsewhere. On M-02877 the device
  # management (Jamf) installs its own, SIP-protected copies of some apps in
  # /Applications, and even root cannot chown those.
  appdir="$(jq -r '(.explicit.appdir // .default.appdir) // empty' \
    "$caskroom/$token/.metadata/config.json" 2>/dev/null || true)"
  live="${appdir:-/Applications}/$app"
  [ -e "$live" ] || live=""
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
