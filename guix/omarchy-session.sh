#!/bin/sh
# Launch Omarchy's Hyprland session. Installed into the system profile by
# omarchy-desktop-session in system.scm and named by Exec= in omarchy.desktop.
#
# GDM runs this, so nothing has sourced a shell profile yet: hm-session-vars.sh
# has not run and OMARCHY_PATH is unset. Everything gets resolved here.
set -eu

hm_profile="$HOME/.local/state/nix/profiles/home-manager/home-path"
omarchy_path="$hm_profile/share/omarchy"

# Hyprland comes from the nixarchy overlay via the omarchy package's
# passthru.runtimeDeps, not from Guix. Guix does package hyprland (0.55.4), and
# switching to it means pointing this one variable at
# /run/current-system/profile/bin/Hyprland -- but nixarchy pins 0.56.2 from the
# Hyprland flake and that is the pair upstream tests the Lua config against.
hyprland="$hm_profile/bin/Hyprland"

# The upstream watchdog, which is what Hyprland wants to be started by.
#
# Launching $hyprland directly logs "WARNING: Hyprland is being launched without
# start-hyprland. This is highly advised against." and gives up what the
# watchdog provides: it holds a pipe fd Hyprland writes to, and on an unclean
# exit it restarts the compositor instead of dropping the whole session back to
# the greeter. On a machine where the session IS the desktop that is worth
# having.
#
# Verified not to be a nixGL problem here, which was the reason to check rather
# than just use it: start-hyprland refuses to run, or wraps with nixGL, when it
# decides the Nix Hyprland cannot reach a GPU. It looks at /etc/NIXOS and
# /run/opengl-driver -- and Guix has no /etc/NIXOS but DOES have
# /run/opengl-driver, pointed at non-nixos-gpu by the symlink service in
# system.scm. Run against a stub compositor it reported no nixGL complaint and
# exited cleanly, and `start-hyprland -- --verify-config --config ...` still
# answers `config ok`, which also proves arguments after `--` reach Hyprland.
#
# Guarded rather than assumed: if a future Hyprland drops the binary, fall back
# to launching the compositor directly. A warning in the log is a much smaller
# problem than a session that cannot start.
start_hyprland="$hm_profile/bin/start-hyprland"

# Omarchy's 460 scripts are unwrapped by design -- the CLI scans them for
# metadata comments and wrapping breaks that -- so their dependencies have to be
# on the session PATH instead. They call hyprctl, quickshell and uwsm-app by
# bare name, never by store path, which is what makes this work at all.
#
# /run/current-system/profile keeps the Guix side reachable: loginctl (elogind),
# herd (shepherd), dbus-update-activation-environment.
#
# Set BEFORE the log block below, not after it: the mkdir and date on the next
# few lines are themselves bare-name lookups. Verified with `env -i` (the worst
# case GDM could hand us) while PATH was still exported further down -- the
# script died with "mkdir: command not found" before the log it writes the
# diagnosis to existed, which is the one failure mode this whole file is
# structured to avoid.
export OMARCHY_PATH="$omarchy_path"
# /run/privileged/bin FIRST, ahead of the system profile.
#
# Ordering, not just membership, and getting it wrong broke sudo for the whole
# session: /run/current-system/profile/bin/sudo is the plain store binary, and
# only /run/privileged/bin/sudo carries the setuid bit (-r-sr-xr-x, root).
# With the profile searched first, `sudo` resolved to the unprivileged copy and
# every invocation died with "must be owned by uid 0 and have the setuid bit
# set". Guix's own /etc/profile prepends this directory for exactly this reason.
#
# /run/setuid-programs is the legacy name -- a farm of symlinks into
# /run/privileged/bin -- and is kept last as a fallback for an older system
# generation that has no /run/privileged.
export PATH="/run/privileged/bin:$hm_profile/bin:$omarchy_path/bin:/run/current-system/profile/bin:/run/setuid-programs${PATH:+:$PATH}"

# A session that exits drops straight back to the greeter with nothing printed
# anywhere, so keep a log the next GNOME login can read. Truncated per run: the
# failure worth diagnosing is always the most recent one.
log="$HOME/.local/state/omarchy-session.log"
# Not `set -e`'s implicit abort: if this fails there is no log to explain why,
# which is the one outcome this block exists to prevent.
if ! mkdir -p "$HOME/.local/state"; then
  echo "omarchy-session FATAL: cannot create $HOME/.local/state" >&2
  exit 1
fi
exec >"$log" 2>&1
echo "omarchy-session: starting $(date -Is)"

if [ ! -d "$omarchy_path" ]; then
  echo "FATAL: no Omarchy tree at $omarchy_path"
  echo "The nixarchy home-manager module installs it."
  echo "Run 'just deploy-mahakala-hm-only' and retry."
  exit 1
fi

if [ ! -x "$hyprland" ]; then
  echo "FATAL: no Hyprland at $hyprland"
  echo "It arrives via the omarchy package's passthru.runtimeDeps."
  exit 1
fi

# Omarchy assumes uwsm started the session and put these in the systemd user
# environment. There is no user manager here, so set them directly; Quickshell
# and the portal both read XDG_CURRENT_DESKTOP.
export XDG_CURRENT_DESKTOP=Hyprland
export XDG_SESSION_TYPE=wayland

# pam_elogind gives us XDG_RUNTIME_DIR, but Hyprland, Quickshell and the
# replaced omarchy-launch-shell all write under it unconditionally, so it is
# defaulted rather than assumed.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Everything below is what ~/.profile would have done. GDM sources no shell
# profile for a Wayland session, and on this machine ~/.profile is what runs
# Guix Home's setup-environment and on-first-login -- so without this a login
# that happens BEFORE any GNOME login has no session D-Bus at all. Verified
# 2026-09-19: /run/user/1000/bus is owned by the Guix Home shepherd (pid 2005),
# not by GDM, and `dbus` is a shepherd service alongside pipewire and
# gpg-agent. gdm-wayland-session contains no dbus-run-session.
#
# Without a bus the failures are all silent rather than fatal, which is worse:
# omarchy-theme-set-gnome exits 0 at its own `[ -z "$DBUS_SESSION_BUS_ADDRESS" ]`
# guard so theming never applies, autostart.lua's
# dbus-update-activation-environment has nothing to talk to, and notifications
# and the polkit agent never register.
#
# setup-environment is sourced (it only exports) and also supplies XDG_DATA_DIRS
# and GSETTINGS_SCHEMA_DIR -- without it XDG_DATA_DIRS falls back to
# /usr/local/share:/usr/share, neither of which exists on Guix, which would
# leave the app launcher with no .desktop files and gsettings with no schemas.
# HOME_ENVIRONMENT first, and `set +u` around the source: setup-environment's
# own header says the caller must export HOME_ENVIRONMENT, and its body reads
# $GUIX_LOCPATH and $XDG_DATA_DIRS unquoted in `case` guards. Under `set -eu`
# sourcing it aborts on line 3 with "HOME_ENVIRONMENT: unbound variable"
# (verified 2026-09-19), which would end the session before Hyprland ran.
if [ -r "$HOME/.guix-home/setup-environment" ]; then
  HOME_ENVIRONMENT="$HOME/.guix-home"
  export HOME_ENVIRONMENT
  set +u
  # shellcheck source=/dev/null
  . "$HOME_ENVIRONMENT/setup-environment"
  set -u
  unset HOME_ENVIRONMENT
fi

# Starts the user shepherd, which is what actually brings up dbus, pipewire and
# gpg-agent. Self-guarding: it claims $XDG_RUNTIME_DIR/on-first-login-executed
# with O_EXCL, so a second session -- or a GNOME login that already ran it --
# makes this a no-op rather than a second shepherd.
if [ -x "$HOME/.guix-home/on-first-login" ]; then
  "$HOME/.guix-home/on-first-login" || true
fi

# The guix the user pulled, ahead of the system's.
#
# /etc/profile sources each profile's own etc/profile in an order that leaves
# ~/.config/guix/current first; setup-environment above does not do this, so
# without it `guix` resolves to /run/current-system/profile/bin/guix -- a
# different, older binary that knows only the channels the SYSTEM was built
# with. Measured in this session: `guix describe` listed guix alone, and
# `guix system build guix/system.scm` failed with "no code for module (nongnu
# packages linux)", while ~/.config/guix/current/bin/guix reported all four
# channels (guix, nonguix, rde, rosenthal) and built the same file cleanly.
#
# Same class of bug as the sudo ordering above: the binary was present and the
# wrong one won.
if [ -d "$HOME/.config/guix/current/bin" ]; then
  export PATH="$HOME/.config/guix/current/bin:$PATH"
fi

# setup-environment prepends the Guix profiles to PATH, so re-assert the
# Omarchy side: its 460 scripts call hyprctl and quickshell by bare name, and
# Guix's hyprland (0.55.4) must not win over the 0.56 the Lua config is tested
# against.
#
# /run/privileged/bin stays ahead of everything for the setuid reason given
# where PATH is first set: sourcing setup-environment re-prepended the Guix
# profiles, which would otherwise put the non-setuid sudo back in front.
export PATH="/run/privileged/bin:$hm_profile/bin:$omarchy_path/bin:$PATH"

# The Home Manager profile's share/ has to be on XDG_DATA_DIRS too, and nothing
# above puts it there. setup-environment builds XDG_DATA_DIRS from the Guix
# profiles, and hm-session-vars.sh -- which is where Home Manager exports its
# own -- is never sourced, because GDM sources no shell profile and ~/.profile
# only loads the Guix side. Measured 2026-09-19: the final XDG_DATA_DIRS names
# ~/.nix-profile/share, which is a DIFFERENT profile from this one
# (ca5vgrx2... vs xnsx7ifm...), so the Omarchy tree's share/ appeared nowhere.
#
# The visible consequence is the app launcher. Quickshell's DesktopEntries
# reads XDG_DATA_DIRS, and AppLibrary.qml/Menu.qml are built on it (Menu.qml:288
# records the choice of DesktopEntries over a bash enumeration, for icons), so
# all 43 .desktop files this profile installs -- foot, emacs, btop, chromium --
# were absent from the launcher while their binaries were on PATH. Prepended so
# that a Guix .desktop of the same name still wins, matching how PATH above
# resolves the same collision.
export XDG_DATA_DIRS="$hm_profile/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"

# Fontconfig, for the same reason and from the same missing file. There is no
# /etc/fonts on Guix System at all, so fontconfig has no default config to fall
# back to: without FONTCONFIG_FILE every process in the session starts with
# "Fontconfig error: Cannot load default config file: File not found" and then
# resolves nothing. hm-session-vars.sh is again where this is normally exported
# (line 46), and again nothing sources it here.
#
# Measured in a real seat0 session 2026-09-20: foot opened with
# "Noto Sans Regular: font does not appear to be monospace" and drew the shell
# in a PROPORTIONAL face, because `fc-match monospace` could not run the
# monospace->JetBrains Mono rule that ~/.config/fontconfig/fonts.conf carries.
# With this set the same lookup answers JetBrains Mono, and sans-serif still
# answers Noto Sans, so nothing else moves.
#
# Guix Home writes that file (it is a store symlink under ~/.config), so this
# names the path rather than a store path: regenerating the home environment
# must not leave the session pointing at a collected config.
if [ -r "$HOME/.config/fontconfig/fonts.conf" ]; then
  export FONTCONFIG_FILE="$HOME/.config/fontconfig/fonts.conf"
fi

# A session bus, if nothing above provided one. dbus-run-session below would be
# the alternative, but that would nest a second bus under the shepherd's.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

# Locales for the Nix half of the session, from the same missing file as
# FONTCONFIG_FILE above and XDG_DATA_DIRS before it.
#
# Guix sets GUIX_LOCPATH, which Guix's glibc reads and Nix's ignores, so every
# Nix binary in the session tried to load LANG=en_US.utf8 and found nothing.
# Measured with the session's own environment: foot printed
#   err:  setlocale() failed. The most common cause is that the configured
#         locale is not available, or has been misspelled
#   warn: invalid locale, falling back to 'C.UTF-8'
# and with LOCALE_ARCHIVE set the same command is silent and exits 0. C.UTF-8
# breaks sorting, month names, and any multibyte input the terminal handles.
#
# Home Manager already builds the archive and exports it -- as
# LOCALE_ARCHIVE_2_27 in hm-session-vars.sh, which nothing sources here, for the
# same reason the fontconfig and XDG_DATA_DIRS blocks exist. So read the value
# out of that file rather than hardcoding a store path that a rebuild would
# invalidate.
#
# Note Guix's own locale tree carries ONLY C.UTF-8 (verified:
# ~/.guix-home/profile/lib/locale/2.41/ has one entry), so pointing
# GUIX_LOCPATH at en_US would not have worked either -- the en_US.utf8 that does
# exist system-side is a Guix glibc build that Nix's glibc cannot read. The two
# locale worlds have to be satisfied separately.
hm_vars="$hm_profile/etc/profile.d/hm-session-vars.sh"
if [ -z "${LOCALE_ARCHIVE:-}" ] && [ -r "$hm_vars" ]; then
  hm_locale_archive=$(sed -n 's/^export LOCALE_ARCHIVE_2_27="\(.*\)"$/\1/p' "$hm_vars" | tail -n 1)
  if [ -n "$hm_locale_archive" ] && [ -r "$hm_locale_archive" ]; then
    export LOCALE_ARCHIVE="$hm_locale_archive"
  fi
  unset hm_locale_archive
fi
unset hm_vars

# hyprland.lua's bootstrap sets package.path to search ~/.config and
# ~/.local/state before $OMARCHY_PATH, so a user override wins over the store
# copy. The seeded ~/.config/hypr/monitors.lua et al. are what make this parse;
# the bare store tree does not.
if [ -x "$start_hyprland" ]; then
  # --path so the watchdog runs the compositor this script vetted above, rather
  # than resolving Hyprland from PATH itself; everything after -- is Hyprland's.
  exec "$start_hyprland" --path "$hyprland" -- \
    --config "$omarchy_path/config/hypr/hyprland.lua"
fi

echo "note: no start-hyprland at $start_hyprland; launching Hyprland directly."
echo "the compositor will warn about this and will not be restarted if it crashes."
exec "$hyprland" --config "$omarchy_path/config/hypr/hyprland.lua"
