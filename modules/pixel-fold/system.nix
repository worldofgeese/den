{ inputs, ... }:
{
  flake.nixOnDroidConfigurations.pixel-fold =
    inputs.nix-on-droid.lib.nixOnDroidConfiguration {
      pkgs = import inputs.nixpkgs-nod {
        system = "aarch64-linux";
        overlays = [ inputs.nix-on-droid.overlays.default ];
      };
      modules = [
        ({ pkgs, ... }: {
          system.stateVersion = "24.05";
          environment.etcBackupExtension = ".bak";

          nix.extraOptions = ''
            experimental-features = nix-command flakes
          '';

          time.timeZone = "Europe/Copenhagen";

          environment.packages = with pkgs; [
            openssh
            tmux
            git
            htop
            curl
            jq
            ripgrep
            fd
            tree
            neovim
            starship
            bat
            eza
            vim
          ];


          home-manager = {
            config = ./_home.nix;
            backupFileExtension = "hm-bak";
            useGlobalPkgs = true;
          };
        })
      ];
      home-manager-path = inputs.home-manager-nod.outPath;
    };
}
