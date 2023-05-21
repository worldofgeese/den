{ config, pkgs, ... }:

{
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "taohansen";
  home.homeDirectory = "/home/taohansen";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "22.11"; # Please read the comment before changing.

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = with pkgs; [
    devenv
    fd # packages that make Doom better
    findutils # packages that make Doom better
    ripgrep # packages that make Doom better
    nodejs # packages that make Doom better
    isort # packages that make Doom better
    shellcheck # packages that make Doom better
    nixfmt # packages that make Doom better
    jetbrains-mono # packages that make Doom better
    gopass
    tdesktop
    # # Adds the 'hello' command to your environment. It prints a friendly
    # # "Hello, world!" when run.
    # pkgs.hello

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
  ];

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;

    # # You can also set the file content immediately.
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
  };

  # You can also manage environment variables but you will have to manually
  # source
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/taohansen/etc/profile.d/hm-session-vars.sh
  #
  # if you don't want to manage your shell through Home Manager.

  home.sessionVariables = {
    EDITOR = "emacs";
    _JAVA_AWT_WM_NONREPARENTING = 1;
    UPDATE_AUR = 1;
    BROWSER = "firefox";
    npm_config_prefix = "$HOME/.local";
  };
  home.sessionPath = [
    "$HOME/.garden/bin"
    "$HOME/.config/emacs/bin"
  ];

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
  fonts.fontconfig.enable = true;
  # Next 2 lines required to append Nix desktop shortcuts to XDG_DATA_DIRS
  targets.genericLinux.enable = true;
  xdg.mime.enable = true;
  programs.mpv = {
    enable = true;
    config = {
      profile = "gpu-hq";
      gpu-api = "vulkan";
      hwdec = "vaapi";
      force-window = true;
      ytdl-format = "bestvideo+bestaudio";
    };
  };
  programs.topgrade = {
    enable = true;
    settings = {
      assume_yes = true;
      skip_notify = true;
      disable = [ "nix" "node" "containers" "helm" ];
      cleanup = true;
      commands = {
        "Run garbage collection on Nix store" = "nix-collect-garbage";
        "Update Manjaro" = "manjaro-update";
      };
    };
  };
  programs.k9s.enable = true;
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
  programs.git = {
    enable = true;
    userEmail = "59834693+worldofgeese@users.noreply.github.com";
    userName = "worldofgeese";
    signing.signByDefault = true;
    signing.key = "63D28F81460A224A";
  };
  programs.exa = {
    enable = true;
    enableAliases = true;
  };
  programs.bash = {
    enable = true;
    bashrcExtra = ''
      [[ -f ~/.bashrc.backup ]] && . ~/.bashrc.backup
      source /home/taohansen/.config/op/plugins.sh
      source ~/.local/share/blesh/ble.sh
    '';
    profileExtra = ''
      [[ -f ~/.bash_profile.backup ]] && . ~/.bash_profile.backup
      [[ -f ~/.profile.backup ]] && . ~/.profile.backup
    '';
    enableVteIntegration = true;
    historyIgnore = [ "ls" "cd" "exit" "gopass" ];
    shellAliases = {
      cat = "bat";
      cd = "z";
    };
  };
  programs.bat.enable = true;
  programs.zoxide = {
    enable = true;
  };
  programs.atuin = {
    enable = true;
    settings = {
      auto_sync = true;
      sync_frequency = "5m";
      sync_address = "https://api.atuin.sh";
      search_mode = "fuzzy";
    };
  };
  programs.gpg.enable = true;
  programs.password-store.enable = true;
  programs.broot = {
    enable = true;
    settings.modal = true;
  };
  programs.jq.enable = true;
  programs.navi = {
    enable = true;
  };
  programs.pet.enable = true;
  programs.ssh = {
    enable = true;
    controlMaster = "yes";
    controlPersist = "10m";
    matchBlocks = {
      "mother" = {
        hostname = "100.102.219.98";
        user = "taohansen";
        port = 2235;
      };
    };
  };
  programs.starship = {
    enable = true;
  };
  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 60480000;
    defaultCacheTtlSsh = 60480000;
    maxCacheTtl = 60480000;
    maxCacheTtlSsh = 60480000;
    enableSshSupport = true;
    sshKeys = [
      "D615D7E91A02052C49082959B9F2F50C2D14C21A"
      "90B63AAB0529F8EA3DBAEA2B1608B9C111896671"
    ];
  };
}
