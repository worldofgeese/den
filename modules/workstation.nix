{ den, ... }:
{
  den.aspects.workstation = {
    includes = [
      den.aspects.sharedDevtools
      den.aspects.terminal
    ];
    homeManager = { pkgs, ... }: {
      # Linux workstation-specific packages (shared tools come from shared-devtools)
      home.packages = (with pkgs; [
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
      ]) ++ [
        # gc — Gas City CLI proxied to remote container on loving-kypris
        (pkgs.writeShellScriptBin "gc" (builtins.readFile ../scripts/gc-remote.sh))
      ];

      xdg.configFile."autostart/synology-drive.desktop" = {
        source = "${pkgs.synology-drive-client}/share/applications/synology-drive.desktop";
        force = true;
      };

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
            disable = [ "nix" "home_manager" "node" "containers" "helm" "guix" "bun" "emacs" "claude_code" "pi" "system" "distrobox" ];
          };
          commands = {
            "Doom Emacs" = "doom upgrade --force";
            "Distrobox (arch)" = "distrobox-upgrade arch";
            "Homebrew (arch distrobox)" = "LC_ALL=C LANG=C distrobox enter arch -- bash --login -c 'brew update && brew upgrade'";
          };
          post_commands = {
            "Garbage collect Nix" = "nix-collect-garbage -d";
            "Garbage collect Guix" = "guix package --delete-generations && guix home delete-generations && (sudo guix system delete-generations 1d || true) && sudo guix gc";
            "Remove unused Flatpak runtimes" = "flatpak uninstall --unused -y";
            "Prune Podman images" = "podman image prune -a -f";
            "Empty Trash" = "chmod -R u+w ~/.local/share/Trash/files ~/.local/share/Trash/info 2>/dev/null || true; rm -rf ~/.local/share/Trash/files/* ~/.local/share/Trash/info/*";
          };
        };
      };
    };
  };
}
