{ config, lib, pkgs, ... }:

{
  home.stateVersion = "24.05";

  programs.starship = {
    enable = true;
    settings = {
      format = lib.concatStrings [
        "$directory"
        "$git_branch"
        "$git_status"
        "$character"
      ];
      directory.truncation_length = 2;
      character = {
        success_symbol = "[λ](purple)";
        error_symbol = "[λ](red)";
      };
    };
  };

  programs.tmux = {
    enable = true;
    baseIndex = 1;
    escapeTime = 0;
    terminal = "screen-256color";
    extraConfig = ''
      set -g mouse on
      set -g status-style "bg=#1e1e2e,fg=#cdd6f4"
      set -g status-left "#[fg=#b4befe,bold] #S "
      set -g status-right "#[fg=#6c7086] %H:%M"
      set -g pane-active-border-style "fg=#b4befe"
    '';
  };

  programs.git = {
    enable = true;
    userName = "Tao Hansen";
    extraConfig.init.defaultBranch = "main";
  };

  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "eza -la --icons";
      la = "eza -a --icons";
      lt = "eza --tree --icons";
      cat = "bat --plain";
      g = "git";
      gs = "git status";
      cc-sessions = "ssh openclaw tmux ls";
      cc-attach = "ssh -t openclaw tmux attach -t";
    };
    initExtra = ''
      eval "$(starship init bash)"

      if [ ! -f "$HOME/.ssh/sshd_host_ed25519_key" ]; then
        ssh-keygen -t ed25519 -f "$HOME/.ssh/sshd_host_ed25519_key" -N ""
      fi
      if ! pgrep -x sshd > /dev/null 2>&1; then
        sshd -p 8022 -h "$HOME/.ssh/sshd_host_ed25519_key"
      fi
    '';
  };

  programs.ssh = {
    enable = true;
    matchBlocks = {
      openclaw = {
        hostname = "100.86.104.77";
        user = "node";
        port = 2222;
        identityFile = "~/.ssh/id_ed25519";
      };
      loving-kypris = {
        hostname = "loving-kypris.hound-celsius.ts.net";
        user = "worldofgeese";
      };
      paphos = {
        hostname = "paphos.hound-celsius.ts.net";
        user = "kypris";
      };
    };
  };
}
