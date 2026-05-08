{ den, ... }:
{
  den.aspects.dktaohan = {
    includes = [
      den.aspects.ssh
    ];

    homeManager = { pkgs, lib, config, ... }: {
      home.username = "dktaohan";
      home.homeDirectory = "/Users/dktaohan";
      home.stateVersion = "25.05";

      programs.home-manager.enable = true;
      xdg.enable = true;
      fonts.fontconfig.enable = true;

      home.sessionVariables = {
        EDITOR = "zed";
      };

      home.sessionPath = [
        "$HOME/bin"
        "$HOME/.local/bin"
        "/opt/homebrew/bin"
        "$HOME/.dotnet/tools"
      ];

      home.shellAliases = {
        "apply-M-02877" = "nix flake update --flake ~/.config/home-manager && sudo -H darwin-rebuild switch --flake ~/.config/home-manager#M-02877";
        fleek-apply = "nix flake update --flake ~/.config/home-manager && sudo -H darwin-rebuild switch --flake ~/.config/home-manager#M-02877";
        catp = "bat -P";
        cat = "bat";
        du = "dust";
        df = "duf";
        ps = "procs";
        find = "fd";
      };

      home.packages = with pkgs; [
        alejandra
        nh
        headsetcontrol
        texlive.combined.scheme-small
        vale
        nodejs
        pnpm
        bun
        uv
        rustup
        saml2aws
        kubectl
        kubernetes-helm
        helm-dashboard
        fluxcd
        docker-compose
        podman-compose
        podman-desktop
        devpod
        odo
        secretspec
        glab
        ripgrep
        jq
        yq-go
        cheat
        just
        zed-editor
        exercism
        decapod
        claude-code-bin
        fd
        dust
        duf
        procs
        sd
        tokei
        bandwhich
        grex
        hyperfine
        shellcheck
        nerd-fonts.fira-code
        freeciv
      ];

      programs.git = {
        enable = true;
        ignores = [ ".direnv" "result" ];
        settings = {
          user.name = "Tao Hansen";
          user.email = "tao.hansen@lego.com";
          feature.manyFiles = true;
          init.defaultBranch = "main";
          gpg.format = "ssh";
          aliases = {
            pushall = "!git remote | xargs -L1 git push --all";
            graph = "log --decorate --oneline --graph";
            add-nowhitespace = "!git diff -U0 -w --no-color | git apply --cached --ignore-whitespace --unidiff-zero -";
          };
          signing = {
            signByDefault = true;
            key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbIQYGvgicAePeJgXJY2wTFMjna8zHSIfqppFB0edOV";
          };
          lfs.enable = true;
        };
      };

      programs.delta = {
        enable = true;
        options = {
          navigate = true;
          side-by-side = true;
          line-numbers = true;
          syntax-theme = "Dracula";
          dark = true;
        };
      };

      programs.direnv = {
        enable = true;
        nix-direnv.enable = true;
        silent = true;
      };

      programs.eza = {
        enable = true;
        icons = "auto";
        git = true;
        extraOptions = [
          "--group-directories-first"
          "--header"
        ];
      };

      programs.bat = {
        enable = true;
        config.theme = "Dracula";
      };

      programs.fzf = {
        enable = true;
        defaultCommand = "fd --type f --hidden --follow --exclude .git";
        defaultOptions = [
          "--height 40%"
          "--border"
          "--layout=reverse"
          "--info=inline"
          "--color=fg:#f8f8f2,bg:#282a36,hl:#bd93f9"
          "--color=fg+:#f8f8f2,bg+:#44475a,hl+:#bd93f9"
          "--color=info:#ffb86c,prompt:#50fa7b,pointer:#ff79c6"
          "--color=marker:#ff79c6,spinner:#ffb86c,header:#6272a4"
        ];
        fileWidgetCommand = "fd --type f --hidden --follow --exclude .git";
        fileWidgetOptions = [ "--preview 'bat --color=always --style=numbers --line-range=:500 {}'" ];
        changeDirWidgetCommand = "fd --type d --hidden --follow --exclude .git";
        changeDirWidgetOptions = [ "--preview 'eza --tree --color=always --icons {} | head -200'" ];
        tmux.enableShellIntegration = true;
      };

      programs.zoxide.enable = true;
      programs.dircolors.enable = true;
      programs.jq.enable = true;
      programs.lazygit.enable = true;
      programs.awscli.enable = true;

      programs.atuin = {
        enable = true;
        settings = {
          auto_sync = false;
          search_mode = "fuzzy";
          filter_mode = "global";
          style = "compact";
          show_help = false;
          show_tabs = false;
          enter_accept = true;
        };
      };

      programs.neovim = {
        enable = true;
        vimAlias = true;
        vimdiffAlias = true;
        withRuby = false;
        withPython3 = false;
      };

      programs.btop = {
        enable = true;
        settings = {
          color_theme = "dracula";
          theme_background = false;
          vim_keys = true;
        };
      };

      programs.tmux = {
        enable = true;
        terminal = "tmux-256color";
        mouse = true;
        historyLimit = 50000;
        escapeTime = 0;
        baseIndex = 1;
        keyMode = "vi";
        customPaneNavigationAndResize = true;
        plugins = with pkgs.tmuxPlugins; [
          sensible
          yank
          resurrect
          continuum
          vim-tmux-navigator
          dracula
        ];
        extraConfig = ''
          set -ag terminal-overrides ",xterm-256color:RGB"
          set -g renumber-windows on
          set -g @resurrect-capture-pane-contents 'on'
          set -g @continuum-restore 'on'
          set -g @continuum-save-interval '10'
          set -g @dracula-show-powerline true
          set -g @dracula-plugins "cpu-usage ram-usage time"
          set -g @dracula-show-left-icon session
        '';
      };

      programs.wezterm = {
        enable = true;
        extraConfig = ''
          local wezterm = require 'wezterm'
          local config = wezterm.config_builder()
          config.color_scheme = 'Dracula (Official)'
          config.font = wezterm.font_with_fallback({
            { family = 'FiraCode Nerd Font', weight = 'Regular' },
            'Fira Code',
          })
          config.font_size = 14.0
          config.line_height = 1.1
          config.window_padding = { left = 12, right = 12, top = 12, bottom = 12 }
          config.window_decorations = 'RESIZE'
          config.window_background_opacity = 0.95
          config.macos_window_background_blur = 20
          config.use_fancy_tab_bar = true
          config.hide_tab_bar_if_only_one_tab = true
          config.tab_max_width = 32
          config.default_cursor_style = 'BlinkingBar'
          config.cursor_blink_rate = 500
          config.scrollback_lines = 10000
          config.keys = {
            { key = 'd', mods = 'CMD', action = wezterm.action.SplitHorizontal({ domain = 'CurrentPaneDomain' }) },
            { key = 'd', mods = 'CMD|SHIFT', action = wezterm.action.SplitVertical({ domain = 'CurrentPaneDomain' }) },
            { key = 'w', mods = 'CMD', action = wezterm.action.CloseCurrentPane({ confirm = true }) },
            { key = 'k', mods = 'CMD', action = wezterm.action.ClearScrollback('ScrollbackAndViewport') },
          }
          return config
        '';
      };

      programs.nushell = {
        enable = true;
        settings = {
          show_banner = false;
          completions.external = {
            enable = true;
            max_results = 100;
          };
          rm.always_trash = true;
          table = {
            mode = "rounded";
            index_mode = "auto";
          };
        };
      };

      programs.lf = {
        enable = true;
        settings = {
          icons = true;
          hidden = true;
          drawbox = true;
          ignorecase = true;
          preview = true;
          ratios = "1:2:3";
        };
        previewer.source = pkgs.writeShellScript "lf-preview" ''
          case "$1" in
            *.tar*|*.zip|*.gz|*.bz2|*.xz) ${pkgs.atool}/bin/als "$1" ;;
            *.pdf) ${pkgs.poppler-utils}/bin/pdftotext "$1" - ;;
            *) ${pkgs.bat}/bin/bat --color=always --style=numbers --line-range=:200 "$1" 2>/dev/null || echo "binary file" ;;
          esac
        '';
        commands = {
          open = ''
            ''${{
              case $(${pkgs.file}/bin/file --mime-type -Lb "$f") in
                text/*|application/json) $EDITOR "$f" ;;
                *) open "$f" ;;
              esac
            }}
          '';
          mkdir = ''
            ''${{
              printf "Directory name: "
              read ans
              mkdir -p "$ans"
            }}
          '';
        };
        keybindings = {
          "." = "set hidden!";
          D = "delete";
          "<enter>" = "open";
        };
      };

      programs.starship = {
        enable = true;
        enableNushellIntegration = true;
        settings = let
          lang = fg: symbol: {
            inherit symbol;
            style = "bg:color_purple fg:${fg}";
            format = "[ $symbol($version) ](bg:color_purple fg:${fg})";
          };
        in {
          "$schema" = "https://starship.rs/config-schema.json";
          format = lib.concatStrings [
            "[](color_bg)"
            "$os"
            "$username"
            "[](bg:color_purple fg:color_bg)"
            "$directory"
            "[](fg:color_purple bg:color_pink)"
            "$git_branch"
            "$git_status"
            "$git_state"
            "[](fg:color_pink bg:color_cyan)"
            "$nodejs"
            "$rust"
            "$python"
            "$golang"
            "$bun"
            "$dotnet"
            "$package"
            "[](fg:color_cyan bg:color_green)"
            "$nix_shell"
            "$direnv"
            "$docker_context"
            "$kubernetes"
            "$aws"
            "[](fg:color_green bg:color_comment)"
            "$time"
            "[ ](fg:color_comment)"
            "$line_break"
            "$cmd_duration"
            "$character"
          ];
          palette = "dracula";
          palettes.dracula = {
            color_fg = "#f8f8f2";
            color_bg = "#282a36";
            color_current = "#44475a";
            color_comment = "#6272a4";
            color_cyan = "#8be9fd";
            color_green = "#50fa7b";
            color_orange = "#ffb86c";
            color_pink = "#ff79c6";
            color_purple = "#bd93f9";
            color_red = "#ff5555";
            color_yellow = "#f1fa8c";
          };
          os = {
            disabled = false;
            style = "bg:color_bg fg:color_fg";
            symbols.Macos = "🍎";
          };
          username = {
            show_always = true;
            style_user = "bg:color_bg fg:color_fg";
            style_root = "bg:color_bg fg:color_red";
            format = "[ $user ]($style)";
          };
          directory = {
            style = "bg:color_purple fg:color_fg";
            format = "[ $path ]($style)";
            truncation_length = 4;
            truncation_symbol = "…/";
            truncate_to_repo = true;
          };
          git_branch = {
            symbol = "🌿";
            style = "bg:color_pink fg:color_bg";
            format = "[ $symbol $branch ](bg:color_pink fg:color_bg)";
          };
          git_status = {
            style = "bg:color_pink fg:color_bg";
            format = "[($all_status$ahead_behind )](bg:color_pink fg:color_bg)";
          };
          git_state = {
            style = "bg:color_pink fg:color_bg";
            format = "[$state( $progress_current/$progress_total) ](bg:color_pink fg:color_bg)";
          };
          nodejs = lang "color_bg" "🟢";
          rust = lang "color_bg" "🦀";
          python = lang "color_bg" "🐍";
          golang = lang "color_bg" "🐹";
          bun = lang "color_bg" "🧅";
          dotnet = lang "color_bg" "🟣";
          package = {
            style = "bg:color_cyan fg:color_bg";
            format = "[ 📦$version ](bg:color_cyan fg:color_bg)";
          };
          nix_shell = {
            style = "bg:color_green fg:color_bg";
            format = "[ ❄️ $state( \\($name\\)) ](bg:color_green fg:color_bg)";
          };
          direnv = {
            disabled = false;
            style = "bg:color_green fg:color_bg";
            format = "[ 📂direnv ](bg:color_green fg:color_bg)";
          };
          docker_context = {
            symbol = "🐳";
            style = "bg:color_green fg:color_bg";
            format = "[ $symbol$context ](bg:color_green fg:color_bg)";
          };
          kubernetes = {
            disabled = false;
            symbol = "☸️";
            style = "bg:color_green fg:color_bg";
            format = "[ $symbol$context(/$namespace) ](bg:color_green fg:color_bg)";
          };
          aws = {
            symbol = "☁️";
            style = "bg:color_green fg:color_bg";
            format = "[ $symbol$profile(/$region) ](bg:color_green fg:color_bg)";
          };
          time = {
            disabled = false;
            time_format = "%H:%M";
            style = "bg:color_comment fg:color_fg";
            format = "[ 🕐$time ](bg:color_comment fg:color_fg)";
          };
          line_break.disabled = false;
          cmd_duration = {
            min_time = 2000;
            format = "⏱️ [$duration]($style) ";
            style = "bold color_yellow";
          };
          character = {
            success_symbol = "[❯](bold color_green)";
            error_symbol = "[❯](bold color_red)";
            vimcmd_symbol = "[❮](bold color_purple)";
          };
        };
      };

      programs.gh = {
        enable = true;
        gitCredentialHelper.enable = true;
        settings = {
          git_protocol = "ssh";
          prompt = "enabled";
          editor = "zed";
        };
        extensions = with pkgs; [ gh-dash ];
      };

      programs.k9s = {
        enable = true;
        settings.k9s = {
          liveViewAutoRefresh = true;
          refreshRate = 2;
          ui = {
            enableMouse = true;
            noIcons = false;
            skin = "dracula";
          };
        };
      };

      programs.topgrade = {
        enable = true;
        settings = {
          misc = {
            assume_yes = true;
            disable = [
              "nix" "home_manager" "brew_formula" "brew_cask"
              "bun" "bun_packages" "bob" "helm"
              "github_cli_extensions" "rustup"
            ];
            cleanup = true;
            set_title = true;
          };
          commands = {
            "Nix-Darwin" = "nix flake update --flake ~/.config/home-manager && sudo -H darwin-rebuild switch --flake ~/.config/home-manager#M-02877";
          };
        };
      };

      programs.ssh = {
        enable = true;
        matchBlocks = {
          "*" = {
            addKeysToAgent = "yes";
            extraOptions = {
              ControlMaster = "auto";
              ControlPersist = "yes";
            };
          };
          "github.com" = {
            hostname = "github.com";
            user = "git";
            identityFile = "~/.ssh/my_ssh_key";
          };
        };
      };

      programs.zsh.dotDir = "${config.xdg.configHome}/zsh";
      programs.zsh.profileExtra = ''
        [ -r ~/.nix-profile/etc/profile.d/nix.sh ] && source  ~/.nix-profile/etc/profile.d/nix.sh
        export XCURSOR_PATH=$XCURSOR_PATH:/usr/share/icons:~/.local/share/icons:~/.icons:~/.nix-profile/share/icons
      '';
      programs.zsh.initContent = ''
        if [ -z "''${HOMEBREW_GITHUB_API_TOKEN:-}" ]; then
          token=""
          if command -v secretspec &>/dev/null; then
            token="$(secretspec get HOMEBREW_GITHUB_API_TOKEN 2>/dev/null || true)"
          fi
          if [ -z "$token" ] && command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
            token="$(gh auth token)"
          fi
          if [ -n "$token" ]; then
            export HOMEBREW_GITHUB_API_TOKEN="$token"
          fi
        fi
      '';
      programs.zsh.enable = true;
    };
  };
}
