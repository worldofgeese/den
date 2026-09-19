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
      home.packages = with pkgs; [
        gsettings-desktop-schemas
        gnome-themes-extra
      ];
    };
  };
}
