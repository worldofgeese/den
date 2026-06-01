{
  den,
  inputs,
  ...
}: {
  den.aspects.workstation = {
    includes = [
      den.aspects.pi
      den.aspects.terminal
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
          wl-clipboard
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
          opencode
          agent-browser
          beeper
        ])
        ++ [
          # gc — Gas City CLI proxied to remote container on loving-kypris
          (pkgs.writeShellScriptBin "gc" (builtins.readFile ../scripts/gc-remote.sh))
        ];

      # Guix system fonts: HM fontconfig only knows Nix store paths, so GTK/GNOME
      # apps show tofu (□□□) for fonts installed by Guix. Add both system and
      # user Guix font directories.
      xdg.configFile."fontconfig/conf.d/90-guix-fonts.conf".text = ''
        <?xml version="1.0"?>
        <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
        <fontconfig>
          <dir>/run/current-system/profile/share/fonts</dir>
          <dir prefix="relative">.guix-home/profile/share/fonts</dir>
        </fontconfig>
      '';

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
          pre_commands = {
            "1. Upgrade CachyOS kernel metadata" = "cd ~/.config/home-manager && just upgrade-kernel";
            "2. Deploy mahakala via Justfile" = "cd ~/.config/home-manager && just deploy-mahakala";
          };
          misc = {
            show_distribution_summary = false;
            disable = ["nix" "home_manager" "node" "containers" "helm" "guix" "bun" "emacs" "claude_code" "pi" "system" "distrobox" "a_m"];
          };
          commands = {
            "Doom Emacs" = "doom upgrade --force";
            "Distrobox (arch)" = "distrobox-upgrade arch";
            "Homebrew (arch distrobox)" = "LC_ALL=C LANG=C distrobox enter arch -- bash --login -c 'brew update && brew upgrade'";
          };
          post_commands = {
            "Garbage collect Nix" = "nix-collect-garbage -d";
            "Garbage collect Guix" = "guix package --delete-generations && guix home delete-generations && (sudo guix system delete-generations 1d 2> >(grep -v 'no matching generation' >&2) || true) && sudo guix gc";
            "Remove unused Flatpak runtimes" = "flatpak uninstall --unused -y";
            "Prune Podman images" = "podman image prune -a -f";
            "Empty Trash" = "chmod -R u+w ~/.local/share/Trash/files ~/.local/share/Trash/info 2>/dev/null || true; rm -rf ~/.local/share/Trash/files/* ~/.local/share/Trash/info/*";
          };
        };
      };
    };
  };
}
