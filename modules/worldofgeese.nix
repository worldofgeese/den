{
  den,
  inputs,
  ...
}: {
  den.aspects.worldofgeese = {
    homeManager = {pkgs, ...}: {
      imports = [inputs.helium.homeModules.default];
      home.username = "worldofgeese";
      home.homeDirectory = "/home/worldofgeese";
      home.enableNixpkgsReleaseCheck = false;

      home.packages = [
        pkgs.nerd-fonts.fira-code
      ];

      programs.home-manager.enable = true;
      programs.helium = {
        enable = true;
        # Upstream uses --set FONTCONFIG_FILE which hard-overrides system fonts.
        # Patch to --set-default so Guix Home's fontconfig takes precedence.
        package = (pkgs.callPackage "${inputs.helium}/helium.nix" {}).overrideAttrs (old: {
          preFixup =
            builtins.replaceStrings
            ["--set FONTCONFIG_FILE"]
            ["--set-default FONTCONFIG_FILE"]
            old.preFixup;
        });
      };
      fonts.fontconfig.enable = true;

      # Expose Guix system and Guix Home font directories to fontconfig so
      # GTK/GNOME apps don't render tofu for fonts only available via Guix.
      xdg.configFile."fontconfig/conf.d/90-guix-fonts.conf".text = ''
        <?xml version='1.0'?>
        <!DOCTYPE fontconfig SYSTEM 'urn:fontconfig:fonts.dtd'>
        <fontconfig>
          <dir>/run/current-system/profile/share/fonts</dir>
          <dir prefix="relative">.guix-home/profile/share/fonts</dir>
        </fontconfig>
      '';
      targets.genericLinux.enable = true;
      targets.genericLinux.gpu.enable = true;
      xdg.mime.enable = true;

      # Identity-specific git config (common settings from git-common aspect)
      programs.git = {
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
          kubernetes = {disabled = true;};
          nodejs = {disabled = true;};

          # The first terminal of a session was printing
          #   [WARN] (starship::context): Scanning current directory timed out
          # and then rendering a prompt with no language/VCS segments.
          #
          # It is a cold-cache effect, not a slow machine, which is why only the
          # FIRST terminal showed it: omarchy-cmd-terminal-cwd has no previous
          # terminal to inherit a directory from, so it falls back to $HOME --
          # 153 entries here, five of them store symlinks -- and starship's
          # default scan_timeout is 30ms. Measured warm, the same scan takes
          # 17ms, so the default sits just under a cold stat of that directory
          # and just over a warm one.
          #
          # 100ms rather than something larger: it has to exceed a cold scan of
          # a home directory, not mask a genuinely pathological one. A prompt
          # that blocks for longer than this is worth being told about.
          scan_timeout = 100;
        };
      };

      # direnv, eza, bat, zoxide, jq, atuin, now come from shared-devtools
      # (included via workstation → shared-devtools)

      programs.atuin.settings = {
        sync_address = "https://api.atuin.sh";
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

      # Helium's upstream .desktop uses absolute Nix store paths for Exec and
      # Icon, which GNOME on Guix System can't resolve. Override with PATH-
      # relative command. Icon placed in local hicolor so GNOME can find it.
      home.file.".local/share/icons/hicolor/256x256/apps/helium.png".source = "${pkgs.callPackage "${inputs.helium}/helium.nix" {}}/share/icons/hicolor/256x256/apps/helium.png";

      xdg.desktopEntries.helium = {
        name = "Helium";
        genericName = "Web Browser";
        comment = "Access the Internet";
        exec = "helium %U";
        terminal = false;
        icon = "helium";
        categories = ["Network" "WebBrowser"];
        mimeType = [
          "text/html"
          "application/xhtml+xml"
          "x-scheme-handler/http"
          "x-scheme-handler/https"
        ];
        startupNotify = true;
        settings = {
          StartupWMClass = "helium";
        };
        actions = {
          new-window = {
            name = "New Window";
            exec = "helium";
          };
          new-private-window = {
            name = "New Incognito Window";
            exec = "helium --incognito";
          };
        };
      };

      dconf.settings = {
        "org/gnome/shell" = {
          enabled-extensions = [
            "appindicatorsupport@rgcjonas.gmail.com"
            "all-in-one-clipboard@NiffirgkcaJ.github.com"
          ];
        };
        "org/gnome/Console" = {
          use-system-font = false;
          custom-font = "JetBrains Mono 11";
        };
      };
    };
  };
}
