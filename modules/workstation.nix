{ den, inputs, ... }:
{
  den.aspects.workstation = {
    homeManager = { pkgs, ... }: {
      home.packages = with pkgs; [
        gopass
        nodejs
        isort
        shellcheck
        nixfmt
        devbox
        openshift
        kubectl
        kubectl-tree
        kubie
        krew
        sops
        httpie
        yt-dlp
        dockfmt
        synology-drive-client
        python-launcher
        yq
        kn
        glab
        megasync
        opencode
        claude-code
        uv
        decapod
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
              "sudo -i guix pull && sudo -E guix system reconfigure ~/.config/guix/system.scm";
            "Upgrade Guix Home then fetch Home Manager deps" =
              "guix pull && guix home reconfigure ~/src/guix-config/home-configuration.scm && nix flake update --flake ~/.config/home-manager";
          };
          misc = {
            disable = [ "nix" "node" "containers" "helm" "guix" "bun" "emacs" "claude_code" ];
          };
          commands = {
            "Doom Emacs" = "doom upgrade --force";
          };
          post_commands = {
            "Garbage collect Nix" = "nix-collect-garbage -d";
            "Garbage collect Guix" = "guix package --delete-generations && guix home delete-generations && sudo guix system delete-generations && sudo guix gc";
            "Remove unused Flatpak runtimes" = "flatpak uninstall --unused -y";
            "Prune Podman images" = "podman image prune -a -f";
            "Empty Trash" = "rm -rf ~/.local/share/Trash/*";
          };
        };
      };

      programs.k9s.enable = true;
    };
  };
}
