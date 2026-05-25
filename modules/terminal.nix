{ den, ... }:
{
  # Shared terminal experience — polished terminal tooling for all workstations.
  # Dracula theme throughout, session persistence, rich previews.
  den.aspects.terminal = {
    homeManager = { pkgs, lib, ... }: {

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

      programs.dircolors.enable = true;
      programs.lazygit.enable = true;

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
          config.use_fancy_tab_bar = true
          config.hide_tab_bar_if_only_one_tab = true
          config.tab_max_width = 32
          config.default_cursor_style = 'BlinkingBar'
          config.cursor_blink_rate = 500
          config.scrollback_lines = 10000
          config.default_prog = { '/home/worldofgeese/.nix-profile/bin/brush', '--login' }
          config.keys = {
            { key = 'd', mods = 'CTRL|SHIFT', action = wezterm.action.SplitHorizontal({ domain = 'CurrentPaneDomain' }) },
            { key = 'd', mods = 'CTRL|SHIFT|ALT', action = wezterm.action.SplitVertical({ domain = 'CurrentPaneDomain' }) },
            { key = 'w', mods = 'CTRL|SHIFT', action = wezterm.action.CloseCurrentPane({ confirm = true }) },
            { key = 'k', mods = 'CTRL|SHIFT', action = wezterm.action.ClearScrollback('ScrollbackAndViewport') },
          }
          return config
        '';
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
                *) xdg-open "$f" 2>/dev/null || open "$f" ;;
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
    };
  };
}
