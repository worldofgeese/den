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
        yt-dlp
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
            "Upgrade Guix System" =
              "sudo guix pull -C ~/.config/home-manager/guix/channels.scm && sudo guix system reconfigure --fallback -L ~/.config/home-manager/guix-packages ~/.config/home-manager/guix/system.scm";
            "Upgrade Guix Home then fetch Home Manager deps" =
              "guix pull && guix home reconfigure ~/.config/home-manager/guix/home-configuration.scm && nix flake update --flake ~/.config/home-manager";
          };
          misc = {
            disable = [ "nix" "node" "containers" "helm" "guix" "bun" "emacs" "claude_code" ];
          };
          commands = {
            "Home Manager" = "home-manager switch --flake ~/.config/home-manager#worldofgeese && update-desktop-database ~/.local/share/applications";
            "Doom Emacs" = "doom upgrade --force";
            "Homebrew (arch distrobox)" = "distrobox enter arch -- bash --login -c 'brew update && brew upgrade'";
          };
          post_commands = {
            "Garbage collect Nix" = "nix-collect-garbage -d";
            "Garbage collect Guix" = "guix package --delete-generations && guix home delete-generations && sudo guix system delete-generations 1+ && sudo guix gc";
            "Remove unused Flatpak runtimes" = "flatpak uninstall --unused -y";
            "Prune Podman images" = "podman image prune -a -f";
            "Empty Trash" = "rm -rf ~/.local/share/Trash/*";
          };
        };
      };
    };
  };
}
