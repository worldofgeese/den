{ inputs, ... }:
{
  flake.nixOnDroidConfigurations.pixel-fold =
    inputs.nix-on-droid.lib.nixOnDroidConfiguration {
      pkgs = import inputs.nixpkgs {
        system = "aarch64-linux";
        overlays = [ inputs.nix-on-droid.overlays.default ];
      };
      modules = [
        ({ pkgs, config, ... }: {
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

          environment.loginShellInit = ''
            if [ ! -f "$HOME/.ssh/sshd_host_ed25519_key" ]; then
              ssh-keygen -t ed25519 -f "$HOME/.ssh/sshd_host_ed25519_key" -N ""
            fi
            if ! pgrep -x sshd > /dev/null 2>&1; then
              sshd -p 8022 -h "$HOME/.ssh/sshd_host_ed25519_key"
            fi
          '';

          home-manager = {
            config = ./_home.nix;
            backupFileExtension = "hm-bak";
            useGlobalPkgs = true;
          };
        })
      ];
      home-manager-path = inputs.home-manager.outPath;
    };
}
