{
  den,
  inputs,
  ...
}: {
  den.aspects.workstation = {
    includes = [
      den.aspects.sharedDevtools
      den.aspects.terminal
      den.aspects.doom-emacs
    ];
    homeManager = {
      pkgs,
      lib,
      ...
    }: {
      nixpkgs.overlays = [
        (final: prev: {
          ewm = inputs.ewm.packages.${pkgs.stdenv.hostPlatform.system}.default;
        })
      ];
      # Linux workstation-specific packages (shared tools come from shared-devtools)
      home.packages =
        (with pkgs; [
          ewm
          brush
          gnomeExtensions.all-in-one-clipboard
          wl-clipboard
          wl-clip-persist
          gopass
          isort
          nixfmt
          devbox
          openshift
          kubectl-tree
          kubie
          krew
          kubernetes-helm # consolidated from Guix Home
          kind # consolidated from Guix Home
          sops
          httpie
          # yt-dlp consolidated to Guix Home (Bordeaux substitute available)
          dockfmt
          synology-drive-client
          python-launcher
          kn
          megasync
          agent-browser
          beeper
          ollama # embedding server for crucible semantic search (shepherd service in guix/home-configuration.scm)
          stdenv.cc.cc.lib # libstdc++.so.6 for Signet's ONNX native module
        ])
        ++ [
          # gc — Gas City CLI proxied to remote container on loving-kypris
          (pkgs.writeShellScriptBin "gc" (builtins.readFile ../scripts/gc-remote.sh))
        ];

      xdg.configFile."autostart/synology-drive.desktop".text = ''
        [Desktop Entry]
        Name=Synology Drive Client
        Comment=Synology Drive Client
        # Force xcb platform: synology-drive-client ships only the Qt xcb
        # plugin, but GNOME's Wayland session causes Qt to look for the
        # wayland plugin first and fail with "Could not find the Qt platform
        # plugin 'wayland'". Forcing xcb makes it run via XWayland.
        Exec=env QT_QPA_PLATFORM=xcb synology-drive start
        Icon=synology-drive
        Terminal=false
        Type=Application
        Categories=Network;FileTransfer;
        X-GNOME-Autostart-enabled=true
      '';

      xdg.configFile."autostart/wl-clip-persist.desktop".text = ''
        [Desktop Entry]
        Name=wl-clip-persist
        Comment=Keep Wayland clipboard after programs close
        Exec=wl-clip-persist --clipboard both
        Terminal=false
        Type=Application
        Categories=Utility;
        X-GNOME-Autostart-enabled=true
      '';

      # GNOME doesn't ship StatusNotifierWatcher, so Qt tray apps (Telegram,
      # Synology Drive) appear to "not start" because their only UI is a tray
      # icon. The AppIndicator extension provides the watcher. It's installed
      # by guix-home into ~/.guix-home/profile/share/gnome-shell/extensions,
      # but `gnome-shell` only scans system extension dirs and
      # ~/.local/share/gnome-shell/extensions, so symlink it into the latter
      # on every activation. After this lands, log out + log back in, then:
      #   gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com
      home.activation.linkAppIndicatorExtension = lib.hm.dag.entryAfter ["writeBoundary"] ''
        ext_id="appindicatorsupport@rgcjonas.gmail.com"
        src="$HOME/.guix-home/profile/share/gnome-shell/extensions/$ext_id"
        dst_dir="$HOME/.local/share/gnome-shell/extensions"
        if [ -e "$src" ]; then
          $DRY_RUN_CMD mkdir -p "$dst_dir"
          $DRY_RUN_CMD ln -sfn "$src" "$dst_dir/$ext_id"
        fi
      '';

      programs.gh = {
        enable = true;
        gitCredentialHelper.enable = true;
        settings = {
          git_protocol = "https";
          prompt = "enabled";
          aliases = {
            co = "pr checkout";
          };
        };
      };

      programs.topgrade = {
        enable = true;
        settings = {
          # Deliberately excludes the kernel. `just upgrade-kernel` used to run
          # here, bumping to whatever CachyOS tagged that day, and the deploy
          # then built it inline for ~3h -- unattended, unreviewed. Worse, the
          # post_commands `guix gc` deleted the result before any reconfigure
          # adopted it, so 12 days of runs landed zero system generations while
          # rebuilding the kernel repeatedly. Kernel upgrades are now explicit:
          #   just upgrade-kernel && just deploy-mahakala-system-full
          #
          # Separate steps rather than one `just deploy-mahakala`, for the same
          # reason as the darwin config: `deploy-mahakala` is a flat recipe, so a
          # persistent Guix forge outage aborted every later line -- including the
          # Home Manager switch, whose closure is already locked and would have
          # succeeded. Split, each failure is contained to its own step. Ordering
          # is preserved by the numeric prefixes (topgrade sorts keys).
          pre_commands = {
            "1. Deploy Guix System" = "cd ~/.config/home-manager && just guix-pull-system && just deploy-mahakala-system";
            "2. Deploy Guix Home" = "cd ~/.config/home-manager && just guix-pull-home && just deploy-mahakala-guix-only";
            "3. Flake inputs" = "cd ~/.config/home-manager && just update";
            "4. Deploy Home Manager" = "cd ~/.config/home-manager && just deploy-mahakala-hm-only";
          };
          misc = {
            assume_yes = true;
            # Retry transient failures instead of aborting the run. `guix pull`
            # fetches four channels from codeberg/sourcehut mirrors, and a single
            # forge hiccup (observed: "Git error: unexpected http status code:
            # 504" from the nonguix mirror) otherwise kills the whole deploy --
            # including the Home Manager switch that had nothing to do with it.
            # ask_retry must be off too, or an unattended run blocks on a prompt.
            auto_retry = 2;
            ask_retry = false;
            pre_sudo = true;
            show_distribution_summary = false;
            disable = ["nix" "home_manager" "containers" "helm" "guix" "bun" "node" "emacs" "claude_code" "pi" "system" "distrobox" "a_m"];
          };
          commands = {
            "Distrobox (arch)" = "distrobox-upgrade arch";
            "Homebrew (arch distrobox)" = "LC_ALL=C LANG=C distrobox enter arch -- bash --login -c 'export HOMEBREW_NO_ASK=1; brew update && brew upgrade'";
          };
          post_commands = {
            "Garbage collect Nix" = "nix-collect-garbage -d";
            # Retain 2w of system generations, not 1d: a same-day kernel needs a
            # rollback target that outlives the day it was deployed. The kernel
            # itself is pinned by the kernel-gc-root GC root in the Justfile.
            "Garbage collect Guix" = "guix package --delete-generations 2w && guix home delete-generations 2w && (sudo guix system delete-generations 2w 2> >(grep -v 'no matching generation' >&2) || true) && sudo guix gc";
            "Remove unused Flatpak runtimes" = "flatpak uninstall --unused -y";
            "Prune Podman images" = "podman image prune -a -f";
            "Empty Trash" = "chmod -R u+w ~/.local/share/Trash/files ~/.local/share/Trash/info 2>/dev/null || true; rm -rf ~/.local/share/Trash/files/* ~/.local/share/Trash/info/*";
          };
        };
      };
    };
  };
}
