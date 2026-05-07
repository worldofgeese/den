{ config, pkgs, ... }:

{
  home.username = "worldofgeese";
  home.homeDirectory = "/home/worldofgeese";
  home.stateVersion = "22.11";

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

  programs.home-manager.enable = true;
  fonts.fontconfig.enable = true;
  targets.genericLinux.enable = true;
  xdg.mime.enable = false;

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

  programs.git = {
    enable = true;
    signing = {
      signByDefault = true;
      key = "63D28F81460A224A";
      format = "openpgp";
    };
    settings = {
      user.email = "59834693+worldofgeese@users.noreply.github.com";
      user.name = "worldofgeese";
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

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.eza.enable = true;
  programs.bat.enable = true;
  programs.zoxide.enable = true;
  programs.jq.enable = true;

  programs.atuin = {
    enable = true;
    settings = {
      auto_sync = true;
      sync_frequency = "5m";
      sync_address = "https://api.atuin.sh";
      search_mode = "fuzzy";
    };
  };

  programs.password-store = {
    enable = true;
    settings = {
      PASSWORD_STORE_DIR = "$XDG_DATA_HOME/password-store";
    };
  };

  programs.broot = {
    enable = true;
    settings.modal = true;
  };

  programs.navi.enable = true;
  programs.pet.enable = true;

  programs.starship = {
    enable = true;
    settings = {
      kubernetes = { disabled = false; };
      nodejs = { disabled = true; };
    };
  };
}
