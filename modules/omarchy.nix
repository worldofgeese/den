#
# Omarchy (via nixarchy) on Guix System.
#
# Only the HOME MANAGER half of nixarchy is imported. nixosModules.nixarchy is
# unusable here: it sets services.displayManager.sessionPackages,
# security.pam.services, security.polkit, boot.plymouth, programs.hyprland,
# xdg.portal, users.users and fonts.packages -- none of which exist outside
# NixOS. The two pieces of it that actually matter are ported into
# guix/system.scm: the GDM session entry (omarchy-desktop-session) and the
# lock-screen PAM stack (omarchy-lock-password).
#
# With osConfig == null the module runs in what nixarchy calls Mode A: no app
# selection, no Install-menu rewrites, no session entry -- and, importantly, it
# adds cfg.package.passthru.runtimeDeps (69 packages) to home.packages, which is
# how Hyprland, Quickshell, hyprlock, foot, libnotify, glib and
# xdg-terminal-exec arrive without being named here. Do NOT re-list any of
# those: home.packages holding two builds of one program is a buildEnv conflict,
# and the module's own comment records that failure surfacing as "two given
# paths contain a conflicting subpath".
#
# WHY QUICKSHELL COMES FROM NIX AND NOT GUIX
#
# Guix does package quickshell, at 0.3.0. Nixarchy enforces a >= 0.3.1 FLOOR
# (flake.nix) because 0.3.0's session lock reaches qFatal when screens sleep and
# wake while locked, and the Wayland session-lock protocol deliberately keeps
# the compositor locked when its lock client disappears -- leaving a blank
# screen with nowhere to type a password and power-cycling as the only way back
# in. Upstream records that happening three times in one night on a real
# machine. So this is a correctness constraint, not a preference.
#
# Guix's hyprland (0.55.4) would probably work, since Omarchy 4.x needs >= 0.55,
# but nixarchy pins 0.56.2 from the Hyprland flake and that is the pair the Lua
# config is tested against. A Lua API mismatch fails at session start, not at
# build time, so the tested pair is worth the closure until there is a reason to
# change it.
#
# THE SYSTEMD PROBLEM
#
# Omarchy assumes a systemd user manager. pid1 here is shepherd. Of the 460
# scripts the coupling was inventoried as: systemctl 33, uwsm 34, journalctl 5,
# systemd-inhibit 3, busctl 5. Most degrade harmlessly, and that was checked
# rather than hoped:
#
#   - omarchy-restart-shell already writes `systemctl --user show-environment
#     2>/dev/null` and falls back to $OMARCHY_PATH.
#   - autostart.lua's two systemd lines are fire-and-forget hl.exec_cmd, and
#     `dbus-update-activation-environment --systemd --all` exits 0 on this
#     machine even with no systemd (verified).
#   - uwsm-app's 30 call sites all funnel through default/hypr/helpers.lua, and
#     `uwsm` itself IS in runtimeDeps, so the binary exists; what is lost is
#     app.slice per-app resource isolation, which has no shepherd equivalent.
#
# Exactly one is fatal and it is on the startup path: omarchy-launch-shell pipes
# Quickshell through `systemd-cat`, which here fails with "Failed to create
# stream fd: No such file or directory" and exit 1 -- so the bar would never
# start. It is replaced below.
{
  den,
  inputs,
  ...
}: {
  den.aspects.omarchy = {
    homeManager = {
      pkgs,
      config,
      lib,
      ...
    }: let
      # omarchy-launch-shell without systemd-cat.
      #
      # Upstream's version exists to keep Quickshell's log out of the tmpfs
      # instance dir, so the idle/lock trail survives a reboot. That reasoning
      # holds here; only the journal does not exist, so the log goes to a file
      # under $XDG_STATE_HOME.
      #
      # The rest of upstream's structure is preserved deliberately: the shell is
      # backgrounded (bash defers a trap until a foreground command returns but
      # interrupts `wait`), the loop distinguishes an interrupted wait from a
      # dead child, and the file watcher stays off so a package upgrade
      # rewriting $OMARCHY_PATH/shell cannot reload against a half-written tree.
      #
      # The `# omarchy:` metadata lines are kept verbatim: bin/omarchy discovers
      # subcommands by grepping siblings for exactly those, so dropping them
      # removes the command from the CLI without an error.
      launchShell = pkgs.writeShellScript "omarchy-launch-shell" ''
        # omarchy:summary=Launch the Omarchy shell with its log kept in a file
        # omarchy:hidden=true

        log_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
        mkdir -p "$log_dir"
        log_file="$log_dir/shell.log"

        # Bounded, or a crash loop fills the disk.
        if [ -f "$log_file" ] && [ "$(stat -c %s "$log_file" 2>/dev/null || echo 0)" -gt 4194304 ]; then
          mv -f "$log_file" "$log_file.1"
        fi

        run_shell() {
          {
            echo "--- quickshell starting $(date -Is)"
            QS_DISABLE_FILE_WATCHER=1 QS_NO_RELOAD_POPUP=1 \
              quickshell -n -p "$OMARCHY_PATH/shell" 2>&1
            echo "--- quickshell exited $? at $(date -Is)"
          } >>"$log_file" 2>&1 &
          shell_pid=$!

          local status
          while true; do
            wait "$shell_pid"
            status=$?

            # An interrupted wait and a shell killed by that signal report alike.
            kill -0 "$shell_pid" 2>/dev/null || break
          done

          shell_pid=""
          return $status
        }

        # A compositor busy reconfiguring outputs can miss a query without
        # being gone, and that is exactly when the shell dies.
        compositor_alive() {
          local attempt
          for attempt in 1 2 3; do
            hyprctl version >/dev/null 2>&1 && return 0
            sleep 1
          done
          return 1
        }

        shell_pid=""
        trap 'if [ -n "$shell_pid" ]; then kill "$shell_pid" 2>/dev/null; fi; exit 0' TERM INT

        while true; do
          run_shell
          compositor_alive || exit 0
          sleep 1
        done
      '';
      # Stands in for uwsm-app, which cannot work without a systemd user
      # manager. See the override in postInstall below for why this exists and
      # what it costs.
      #
      # `exec "$@"` and nothing else: uwsm-app's job here is only to run the
      # command, and the callers already supply setsid where they want the
      # process detached. Keeping it this thin means a caller's exit status and
      # stdio behave exactly as they would without the wrapper.
      uwsmAppShim = pkgs.writeShellScript "uwsm-app" ''
        # omarchy:hidden=true

        # Callers all use `uwsm-app -- CMD ARGS...`; drop the separator so the
        # command is argv[0]. A bare `--` with nothing after it is a no-op
        # rather than an error, matching how uwsm-app treats an empty app.
        [ "''${1-}" = "--" ] && shift
        [ $# -eq 0 ] && exit 0

        exec "$@"
      '';
    in {
      imports = [inputs.nixarchy.homeManagerModules.nixarchy];

      programs.nixarchy = {
        enable = true;

        # The tree with omarchy-launch-shell replaced.
        #
        # Through the module's own `package` option and its default expression,
        # not a separate build: the default is
        # `(pkgs.extend nixarchy.overlays.default).omarchy`, built against THIS
        # flake's nixpkgs, and `inputs.nixarchy.packages.*.omarchy` would be a
        # second copy of ~69 dependencies built against nixarchy's nixpkgs.
        #
        # postInstall, because it runs inside the same derivation and so the
        # replacement is what every caller resolves -- the QML bar, the menu and
        # the CLI alike. A PATH shim would only cover callers that inherit the
        # session PATH, and the guard below makes a rename upstream a BUILD
        # failure rather than a script silently installed under a name nothing
        # calls. That guard is copied from nixarchy's own nix-bin loop
        # (pkgs/omarchy/default.nix:1030), which fails the same way for the same
        # reason.
        package =
          ((pkgs.extend inputs.nixarchy.overlays.default).omarchy).overrideAttrs
          (old: {
            postInstall =
              (old.postInstall or "")
              + ''
                target=$out/share/omarchy/bin/omarchy-launch-shell
                if [ ! -e "$target" ]; then
                  echo "omarchy-launch-shell no longer exists in this Omarchy version;" >&2
                  echo "the Guix systemd-cat replacement in modules/omarchy.nix is stale." >&2
                  exit 1
                fi
                install -Dm755 ${launchShell} "$target"

                # first-run's systemd step, made non-fatal.
                #
                # enable-user-units.sh runs `systemctl --user daemon-reload`
                # under `set -euo pipefail`. With no systemd user manager that
                # prints "Failed to connect to user scope bus via local
                # transport" and exits 1, which aborts the script before its
                # own unit-filtering loop -- the loop nixarchy added precisely
                # so that an ABSENT unit is not fatal.
                #
                # The cost is the same one nixarchy's own header describes for
                # the bug it fixed: omarchy-provision-first-run marks itself
                # done only when every step succeeded, so this single failure
                # means the marker is never written and first-run repeats at
                # every login -- a welcome notification on every boot, for the
                # life of the machine. Measured in first-run.log: four logins,
                # four "first-run will retry next login", with "enable user
                # systemd units" the only step still failing.
                #
                # Made non-fatal rather than removed, so the script's own
                # filtering loop stays the single decision point: with no
                # manager its six `systemctl --user cat` probes all fail, `want`
                # ends up empty and the script exits 0 on its own. On a machine
                # that does have a user manager nothing changes at all, and
                # units that exist still report their own failures.
                units=$out/share/omarchy/install/user/first-run/enable-user-units.sh
                if [ ! -e "$units" ]; then
                  echo "enable-user-units.sh no longer exists in this Omarchy version;" >&2
                  echo "the Guix systemd guard in modules/omarchy.nix is stale." >&2
                  exit 1
                fi
                if ! grep -q '^systemctl --user daemon-reload$' "$units"; then
                  echo "enable-user-units.sh no longer opens with a bare daemon-reload;" >&2
                  echo "the Guix systemd guard in modules/omarchy.nix is stale." >&2
                  exit 1
                fi
                substituteInPlace "$units" \
                  --replace-fail 'systemctl --user daemon-reload' \
                    'systemctl --user daemon-reload || true'

                # uwsm-app, replaced by a shim that just runs the command.
                #
                # THE MOST IMPORTANT OVERRIDE HERE. Measured on this machine:
                # `uwsm-app -- touch /tmp/probe` prints "Failed to connect to
                # user scope bus via local transport", creates no file, and
                # EXITS 0. Every app launch in Omarchy goes through it -- 38
                # call sites, including omarchy-launch-terminal, -browser,
                # -editor, the menu and the bar's app library -- so without this
                # SUPER+Return and every other launch keybind silently does
                # nothing, and the exit 0 means nothing anywhere reports it.
                #
                # Shimmed at uwsm-app rather than at the 29 scripts that call
                # it: every real invocation in the tree is the single form
                # `uwsm-app -- CMD ARGS...` (verified by enumerating all of
                # them; no -s/-a slice flags, and the only non-`--` hits are a
                # doc comment and a QML execDetached argv that is also `--`), so
                # one replacement covers all of them and there is one place to
                # delete when a user manager ever exists.
                #
                # Not a PATH shim, for the reason the rest of this block is not
                # either: the bar and the menu resolve it too, and a store
                # replacement covers callers that never saw the session PATH.
                #
                # What is genuinely lost is uwsm's per-app app.slice scope --
                # each app in its own cgroup, so an OOM kills one app instead of
                # the session. Shepherd has no equivalent, and `setsid` at least
                # keeps the caller's exit from taking the app with it (the
                # launch scripts already prepend it).
                # Installed under a DIFFERENT name and substituted into the
                # callers, rather than shipped as bin/uwsm-app.
                #
                # The obvious version of this -- drop a uwsm-app into
                # $out/bin -- fails the profile build, and that failure is worth
                # recording because it was the plan until the builder rejected
                # it: uwsm is itself in passthru.runtimeDeps, so the real
                # /nix/store/...-uwsm-0.26.7/bin/uwsm-app and ours are two
                # buildEnv paths claiming bin/uwsm-app and home-manager-path
                # exits 25 with "two given paths contain a conflicting subpath".
                #
                # Even had it linked, it would not have WORKED: the session
                # launcher puts $hm_profile/bin ahead of $omarchy_path/bin, so
                # the real uwsm-app -- the broken one -- wins the PATH lookup
                # and the shim is never reached. Verified: the profile's
                # bin/uwsm-app resolves into the uwsm package.
                #
                # So the callers are rewritten to name omarchy-guix-app, which
                # collides with nothing and cannot be shadowed. Every real
                # invocation is the same `uwsm-app -- ` prefix, so this is a
                # single textual substitution across the tree.
                install -Dm755 ${uwsmAppShim} $out/share/omarchy/bin/omarchy-guix-app
                ln -s ../share/omarchy/bin/omarchy-guix-app $out/bin/omarchy-guix-app

                # Rewrite every caller. grep -l rather than a fixed file list so
                # a new launch script in a future Omarchy is covered too, and a
                # count assertion so that "it silently matched nothing" -- the
                # failure mode this whole file is built to avoid -- is a build
                # error instead.
                mapfile -t uwsm_callers < <(grep -rl 'uwsm-app -- ' \
                  $out/share/omarchy/bin $out/share/omarchy/shell \
                  $out/share/omarchy/default 2>/dev/null || true)
                if [ ''${#uwsm_callers[@]} -lt 25 ]; then
                  echo "only ''${#uwsm_callers[@]} uwsm-app callers found; expected ~33." >&2
                  echo "the Guix uwsm shim in modules/omarchy.nix is stale." >&2
                  exit 1
                fi
                for caller in "''${uwsm_callers[@]}"; do
                  substituteInPlace "$caller" \
                    --replace-fail 'uwsm-app -- ' 'omarchy-guix-app -- '
                done

                # The QML argv form, which is a list and so has no ' -- ' to
                # match: ["uwsm-app", "--", "nautilus", ...].
                dropbox=$out/share/omarchy/shell/plugins/panels/dropbox/Service.qml
                if grep -q '"uwsm-app"' "$dropbox"; then
                  substituteInPlace "$dropbox" \
                    --replace-fail '"uwsm-app"' '"omarchy-guix-app"'
                fi

                # Audio restart, via herd instead of systemctl --user.
                #
                # The script's restart function is the only systemd-bound part;
                # its USB-recovery and wpctl health logic below that is
                # service-manager agnostic and worth keeping, so this replaces
                # four commands rather than the file.
                #
                # The three units map one-to-one onto shepherd services of the
                # same name minus `.service` (verified with `herd status`:
                # pipewire, pipewire-pulse, wireplumber are all present), which
                # is why ''${services[@]/.service/} works as the translation.
                #
                # herd has no `cancel`, `kill --kill-whom` or `reset-failed`, so
                # the forced-down path becomes stop-then-start. That is weaker
                # than SIGKILL for a genuinely wedged process, and it is the one
                # behaviour difference: a wireplumber stuck in D-state will not
                # be forced down by this. The USB reset logic further down the
                # script -- which is the actual remedy for stuck USB audio, and
                # the reason the script exists -- still runs.
                audio=$out/share/omarchy/bin/omarchy-restart-audio
                if [ ! -e "$audio" ]; then
                  echo "omarchy-restart-audio no longer exists; the Guix herd" >&2
                  echo "override in modules/omarchy.nix is stale." >&2
                  exit 1
                fi
                substituteInPlace "$audio" \
                  --replace-fail \
                    'if timeout 25s systemctl --user restart "''${services[@]}"; then' \
                    'if timeout 25s herd restart "''${services[@]/.service/}"; then' \
                  --replace-fail \
                    'systemctl --user cancel >/dev/null 2>&1 || true' \
                    ': # no herd equivalent for `systemctl --user cancel`' \
                  --replace-fail \
                    'systemctl --user kill --kill-whom=all --signal=KILL "''${services[@]}" >/dev/null 2>&1 || true' \
                    'for s in "''${services[@]/.service/}"; do herd stop "$s" >/dev/null 2>&1 || true; done' \
                  --replace-fail \
                    'systemctl --user reset-failed "''${services[@]}" >/dev/null 2>&1 || true' \
                    ': # herd has no failed-state to reset' \
                  --replace-fail \
                    'timeout 25s systemctl --user start pipewire.service pipewire-pulse.service wireplumber.service' \
                    'timeout 25s herd start pipewire && timeout 25s herd start pipewire-pulse && timeout 25s herd start wireplumber'

                # Nothing may still name uwsm-app in executable code.
                if grep -rn 'uwsm-app' $out/share/omarchy/bin $out/share/omarchy/shell \
                     | grep -vE '^\S+:[0-9]+:\s*#' | grep -q .; then
                  echo "uwsm-app still referenced in executable code after rewrite:" >&2
                  grep -rn 'uwsm-app' $out/share/omarchy/bin $out/share/omarchy/shell \
                    | grep -vE '^\S+:[0-9]+:\s*#' >&2
                  exit 1
                fi

                # Reboot and shutdown, via loginctl instead of systemd-run.
                #
                # Both scripts open with
                #   systemd-run --user ... systemctl reboot --no-wall || exit 1
                # to schedule the action in the user manager so that closing the
                # calling terminal's scope cannot kill it. systemd-run --user
                # exits 1 here (measured: same user-scope-bus failure), and the
                # `|| exit 1` means the script stops THERE -- before the OSD,
                # before `omarchy-state clear`, before it closes windows. So the
                # power menu appears to do nothing at all.
                #
                # loginctl is the right substitute and it is present: elogind
                # 257 answers, and pkaction reports
                # org.freedesktop.login1.power-off as `implicit active: yes`, so
                # an active session needs no password.
                #
                # The 2-second defer is kept with setsid+sleep rather than
                # dropped: the window-closing below it is the whole point of
                # these two scripts over a bare `loginctl reboot`, and it needs
                # the action to fire after it, not before. setsid detaches so
                # the terminal that ran it can exit -- which is the property
                # systemd-run was there to provide.
                for action in reboot:reboot shutdown:poweroff; do
                  script=$out/share/omarchy/bin/omarchy-system-''${action%%:*}
                  verb=''${action##*:}
                  if [ ! -e "$script" ]; then
                    echo "omarchy-system-''${action%%:*} no longer exists;" >&2
                    echo "the Guix loginctl override in modules/omarchy.nix is stale." >&2
                    exit 1
                  fi
                  substituteInPlace "$script" \
                    --replace-fail \
                      "systemd-run --user --collect --quiet --on-active=\"2s\" --timer-property=AccuracySec=100ms systemctl $verb --no-wall || exit 1" \
                      "setsid sh -c 'sleep 2; exec loginctl $verb' >/dev/null 2>&1 &"
                done
              '';
          });
      };

      # Omarchy's GTK light/dark follow.
      #
      # Upstream ships this as systemd.user.services.omarchy-theme-gnome, which
      # the HM module still writes into ~/.config/systemd/user -- inert here,
      # because nothing reads that directory on this machine.
      #
      # Not a Guix Home shepherd service either: that shepherd starts at LOGIN,
      # before any compositor or theme state exists.
      #
      # `post-boot`, not `theme-changed`. Omarchy has no theme-changed event:
      # omarchy-hook is called with exactly post-boot, theme-set, font-set,
      # battery-low and pre-refresh-pacman (grepped across the 4.0.4 tree), and
      # a hook file under any other name is never read -- so the first version
      # of this was dead code that silently did nothing. A theme-set hook would
      # also be redundant: omarchy-theme-set already runs
      # omarchy-theme-set-gnome and omarchy-cursor-set itself from
      # post_theme_commands (bin/omarchy-theme-set:318-339). What is actually
      # missing on Guix is the once-per-session apply that the systemd unit did,
      # and post-boot is exactly that -- autostart.lua:13 fires it two seconds
      # into the session.
      #
      # The `.d` directory rather than the bare file: it is the documented
      # extension point, and it leaves the single-file path free for the user.
      #
      # Written by activation rather than xdg.configFile because Omarchy
      # documents ~/.config/omarchy/hooks as user-editable, and an
      # xdg.configFile entry is a read-only store symlink. Never overwrites, for
      # the same reason.
      home.activation.omarchyGuixThemeHook = lib.hm.dag.entryAfter ["nixarchySeed"] ''
        hook_dir="${config.xdg.configHome}/omarchy/hooks/post-boot.d"
        hook="$hook_dir/10-guix-apply-gnome-theme"
        if [ ! -e "$hook" ]; then
          run mkdir -p "$hook_dir"
          run install -m 644 ${
          pkgs.writeText "omarchy-post-boot-gnome-theme" ''
            # Apply the current theme's light/dark mode to GTK and the cursor.
            #
            # On NixOS this is systemd.user.services.omarchy-theme-gnome.
            # There is no systemd user manager on Guix System, so it runs once
            # per session from Omarchy's own post-boot hook instead.
            omarchy-theme-set-gnome || true
            omarchy-cursor-set || true
          ''
        } "$hook"
        fi
      '';

      # Omarchy's plain neovim wins over Home Manager's wrapped one.
      #
      # Both are named `neovim-0.12.5` and they are DIFFERENT builds, so
      # home.packages holding both is a real buildEnv conflict -- it fails the
      # profile build with "two given paths contain a conflicting subpath"
      # naming the same version twice. Measured: of the 13 duplicated package
      # names this aspect introduces, neovim is the only one whose two entries
      # resolve to different store paths. The other twelve (bat, btop, eza, fzf,
      # git, jq, lazygit, man-db, starship, tmux, wl-clipboard, zoxide) are the
      # identical path listed twice and Nix dedupes them, so the programs.*
      # blocks configuring them are deliberately left alone -- dropping those
      # would delete real configuration (the dracula tmux theme,
      # resurrect/continuum, btop's vim_keys, the git identity) to fix a
      # conflict that does not exist.
      #
      # mkForce here rather than editing modules/terminal.nix, because that
      # aspect is also applied to dktaohan@M-02877, which has no Omarchy and
      # would just lose its editor.
      #
      # What is actually given up is small: terminal.nix sets only enable,
      # vimAlias, vimdiffAlias and withRuby/withPython3 = false -- no plugins
      # and no extraConfig. `nvim` still comes from Omarchy's runtimeDeps; the
      # two aliases are the only casualty, so they are restored below.
      # ~/.config/nvim itself is untouched either way: nixarchy's `neovim`
      # option defaults to "theme-only", which links a colourscheme and writes
      # nothing else.
      programs.neovim.enable = lib.mkForce false;
      home.shellAliases = {
        vim = "nvim";
        vimdiff = "nvim -d";
      };

      # Nixi, nixarchy's default-on beginner guide, is off here because one of
      # its QML files cannot work on this machine. MenuSearch.qml:21 is a
      # literal `import "file:///run/current-system/sw/share/omarchy/shell/
      # plugins/menu/MenuModel.js"` -- a NixOS system-profile path, hardcoded
      # upstream in nixi-nixarchy itself, with no option to redirect it.
      # /run/current-system on Guix System is a Guix system generation and has
      # no `sw`, so the import resolves to nothing and the shell log carried
      # `Type Conversation unavailable`, `Type MenuSearch unavailable` and
      # `No such file or directory` on every start (measured 2026-09-19).
      #
      # Nothing in Omarchy's own bar, menu or session depends on it: the guide
      # is a nixarchy addition, and upstream's module is entirely
      # `lib.mkIf cfg.enable`, so false leaves no plugin, timer, activation
      # step or package behind. Off is therefore the minimal correct state --
      # a broken card that logs four errors a start is worse than no card.
      services.nixi.enable = false;

      # Which portal backend answers which interface, for this session.
      #
      # Needed because UseIn= does not line up. The backends are installed
      # Guix-side (see guix/system.scm), and there:
      #   hyprland.portal  UseIn=wlroots;Hyprland;sway;...  Screenshot,
      #                    ScreenCast, GlobalShortcuts
      #   gtk.portal       UseIn=gnome                      FileChooser + 11 more
      #
      # The session exports XDG_CURRENT_DESKTOP=Hyprland, so gtk.portal is not
      # selected at all and FileChooser has no implementation -- every GTK
      # open/save dialog and omarchy-file-select would fail. Guix's gtk.portal
      # says gnome because that is the desktop Guix ships it for; it is not a
      # GNOME-specific implementation.
      #
      # portals.conf is the supported instrument for exactly this and it
      # overrides UseIn. Confirmed against the running frontend rather than
      # assumed: xdg-desktop-portal 1.22.1 (>= the 1.17 that introduced it), and
      # its binary contains both the "%s-portals.conf" pattern and the notice
      # that this is "the preferred method to match portal implementations to
      # desktop environments".
      #
      # A user config file rather than a Guix-side one, unlike the backends
      # themselves: the frontend reads ~/.config/xdg-desktop-portal directly, so
      # the profile-visibility problem that forces the packages Guix-side does
      # not apply here.
      #
      # org.freedesktop.impl.portal.Settings is deliberately left to gtk too: it
      # is what carries the light/dark preference to GTK4 and Chromium, and the
      # hyprland backend does not implement it.
      xdg.configFile."xdg-desktop-portal/hyprland-portals.conf".text = ''
        [preferred]
        default=gtk
        org.freedesktop.impl.portal.Screenshot=hyprland
        org.freedesktop.impl.portal.ScreenCast=hyprland
        org.freedesktop.impl.portal.GlobalShortcuts=hyprland
      '';

      # The schemas omarchy-theme-set-gnome writes into. Without them every
      # `gsettings set org.gnome.desktop.interface ...` is a silent no-op --
      # nixarchy's NixOS module documents that exact failure as a dark theme
      # leaving GTK apps and Chromium in light mode. NixOS supplies them through
      # environment.systemPackages; standalone Home Manager has to ask.
      #
      # Only the packages NOT already in passthru.runtimeDeps are listed. glib,
      # libnotify and xdg-terminal-exec are already there (checked against the
      # 69-entry list, after first getting this wrong) and adding them again
      # would be a buildEnv conflict.
      # The font every terminal config Omarchy ships names by family.
      #
      # foot.ini, kitty.conf, alacritty.toml, ghostty/config and
      # default/foot/screensaver.ini all say `JetBrainsMono Nerd Font`, and
      # nothing in passthru.runtimeDeps supplies a font at all (the only
      # font-ish entry is fontconfig itself, checked). nixarchy's NixOS half
      # installs it through fonts.packages, which does not exist here.
      #
      # Measured in a real seat0 session 2026-09-20: `fc-list` matched 0
      # "JetBrainsMono Nerd" families, so foot fell back to Noto Sans and
      # warned "font does not appear to be monospace" -- a proportional
      # terminal. Guix's own JetBrains Mono is installed and is what the
      # generic `monospace` alias resolves to, but it is NOT the Nerd Font
      # patched build, so the glyphs the bar and the terminal prompt draw from
      # the private use area still render as tofu without this.
      #
      # Only this one font, not the rest of nixarchy's fonts.packages list:
      # Noto (sans, serif, CJK, colour emoji) is already installed on this
      # machine through Guix Home, and Liberation is referenced solely by
      # default/fontconfig/conf.avail/50-omarchy.conf, which is upstream's
      # /etc/fonts/conf.d drop-in and is deliberately not installed here --
      # ~/.config/fontconfig/fonts.conf already assigns the three generic
      # families, and FONTCONFIG_FILE in the session launcher is what makes
      # those assignments take effect.
      #
      # Omarchy's own icon font needs nothing: it travels inside the package at
      # share/fonts/truetype/omarchy.ttf, and fonts.conf already lists the
      # profile's share/fonts as a <dir>, so `fc-list` finds it (verified).
      home.packages = with pkgs; [
        gsettings-desktop-schemas
        gnome-themes-extra
        nerd-fonts.jetbrains-mono
      ];
    };
  };
}
