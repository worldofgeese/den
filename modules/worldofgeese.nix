{ den, ... }:
{
  den.aspects.worldofgeese = {
    includes = [ den._.primary-user ];

    homeManager = { pkgs, ... }: {
      home.username = "worldofgeese";
      home.homeDirectory = "/home/worldofgeese";

      programs.home-manager.enable = true;
      fonts.fontconfig.enable = true;
      targets.genericLinux.enable = true;
      xdg.mime.enable = false;

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

      programs.starship = {
        enable = true;
        settings = {
          kubernetes = { disabled = false; };
          nodejs = { disabled = true; };
        };
      };

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
    };
  };
}
