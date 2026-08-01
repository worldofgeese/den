{den, ...}: {
  den.aspects.dktaohan = {
    includes = [
      den.batteries.define-user
      den.batteries.primary-user
      den.aspects.ssh
      den.aspects.pi
      den.aspects.gitcommon
      den.aspects.terminal
    ];

    homeManager = {
      pkgs,
      lib,
      config,
      ...
    }: let
      # Single source of truth for work-profile model routing.
      # tier-defs.json and workTiers are both derived from this, so the
      # agent-override frontmatter can never drift from the tier definitions.
      gatewayModel = id: "anthropic-proxy/${id}";
      workTierDefs = {
        orchestrator = {
          model = gatewayModel "eu.anthropic.claude-opus-5";
          thinking = "high";
          fallbackModels = [];
        };
        creative = {
          model = gatewayModel "eu.anthropic.claude-sonnet-5";
          thinking = "high";
          fallbackModels = [];
        };
        execution = {
          model = gatewayModel "eu.anthropic.claude-sonnet-5";
          thinking = "medium";
          fallbackModels = [(gatewayModel "eu.anthropic.claude-opus-5")];
        };
      };
      workTiers = lib.mapAttrs (_: tier: tier.model) workTierDefs;

      # Model metadata mirrors the gateway's own published catalogue (contextWindow,
      # outputWindow, and data_zone pricing), not Anthropic list prices.
      gatewayModels = [
        {
          id = "eu.anthropic.claude-opus-5";
          name = "Opus 5";
          reasoning = true;
          input = ["text" "image"];
          cost = {
            input = 5.5;
            output = 27.5;
            cacheRead = 0.55;
            cacheWrite = 6.875;
          };
          contextWindow = 1000000;
          maxTokens = 128000;
        }
        {
          id = "eu.anthropic.claude-sonnet-5";
          name = "Sonnet 5";
          reasoning = true;
          input = ["text" "image"];
          cost = {
            input = 2.2;
            output = 11;
            cacheRead = 0.22;
            cacheWrite = 4.4;
          };
          contextWindow = 200000;
          maxTokens = 64000;
        }
        {
          id = "eu.anthropic.claude-haiku-4-5-20251001-v1:0";
          name = "Haiku 4.5";
          reasoning = false;
          input = ["text" "image"];
          cost = {
            input = 0.8;
            output = 4;
            cacheRead = 0.08;
            cacheWrite = 1;
          };
          contextWindow = 200000;
          maxTokens = 8192;
        }
      ];

      # The gateway is a faithful Anthropic Messages passthrough, so pi can talk
      # to it through the built-in `anthropic-messages` API declared in
      # models.json — no provider extension needed. The key is read from the
      # macOS keychain at request time and never touches disk.
      piModelsJson = pkgs.writeText "pi-models.json" (builtins.toJSON {
        providers."anthropic-proxy" = {
          name = "LEGO AI Model Gateway";
          baseUrl = "https://api.genai.thelegogroup.com/anthropic";
          api = "anthropic-messages";
          apiKey = "!secretspec get -f ${config.home.homeDirectory}/.config/home-manager/secretspec.toml LEGO_GATEWAY_API_KEY";
          authHeader = true;
          models = gatewayModels;
        };
      });

      patchAgentModel = file: let
        content = builtins.readFile file;
        lines = lib.splitString "\n" content;
        tierLine = lib.findFirst (l: lib.hasPrefix "tier: " l) null lines;
        tierName =
          if tierLine != null
          then lib.trim (lib.removePrefix "tier:" tierLine)
          else "execution";
        model = workTiers.${tierName} or workTiers.execution;
        modelLine = lib.findFirst (l: lib.hasPrefix "model: " l) null lines;
      in
        if modelLine != null
        then builtins.replaceStrings [modelLine] ["model: ${model}"] content
        else content;
    in {
      programs.home-manager.enable = true;
      xdg.enable = true;
      fonts.fontconfig.enable = true;

      home.sessionVariables = {
        EDITOR = "zed";
      };

      home.sessionPath = [
        "$HOME/bin"
        "$HOME/.local/bin"
        "$HOME/.cargo/bin"
        "$HOME/.local/share/pnpm/bin"
        "/opt/homebrew/bin"
        "$HOME/.dotnet/tools"
      ];

      home.activation.cargoInstall = lib.hm.dag.entryAfter ["writeBoundary"] ''
        export PATH="${pkgs.rustup}/bin:$HOME/.cargo/bin:$PATH"
        run cargo install decapod 2>/dev/null || true
      '';

      # Pi reaches the gateway through a models.json provider, not an extension.
      # models.json is deliberately left unmanaged: it reloads live when /model
      # is opened, so the endpoint can be re-pointed without a rebuild when the
      # proxy chain or gateway is unreachable. Seeded once, never overwritten.
      home.activation.seedPiModelsJson = lib.hm.dag.entryAfter ["writeBoundary"] ''
        models_json="$HOME/.pi/agent/models.json"
        if [ ! -e "$models_json" ]; then
          run mkdir -p "$(dirname "$models_json")"
          run install -m 644 ${piModelsJson} "$models_json"
        fi
      '';

      home.file.".pi/agent/tier-defs.json".text = builtins.toJSON workTierDefs;

      home.file.".pi/agent/settings.json".text = builtins.toJSON {
        provider = "anthropic-proxy";
        model = "eu.anthropic.claude-opus-5";
        defaultThinkingLevel = "high";
        compaction = {
          enabled = true;
        };
        # Work profile deliberately runs a minimal extension set. The shared
        # list in ../../pi-packages.nix still applies to every other host.
        packages = [
          "git:github.com/elpapi42/pi-minimal-subagent"
          "npm:pi-ask-user"
          "npm:pi-compound-engineering"
          # Beads task tracking via the Python `bd` CLI. The shared profile
          # prefers the beads-rust extension (`br`), but that one is force-
          # disabled on this profile, so use the npm package here instead.
          "npm:pi-beads-extension"
        ];
      };

      # Disable the shared aspects.pi extensions on this profile.
      home.file.".pi/agent/extensions/beads-rust/index.ts".enable = lib.mkForce false;
      home.file.".pi/agent/extensions/governance/index.ts".enable = lib.mkForce false;

      # context-mode's binary ships with the npm:context-mode extension, which
      # is no longer installed here, so the MCP server would fail to start.
      home.file.".pi/agent/mcp.json".text = lib.mkForce (builtins.toJSON {
        settings = {
          toolPrefix = "server";
          idleTimeout = 10;
        };
        mcpServers = {
          "agent-mail" = {
            command = "${pkgs.mcp-agent-mail}/bin/mcp-agent-mail";
            args = ["serve-stdio"];
            lifecycle = "lazy";
            directTools = true;
            env = {
              WORKTREES_ENABLED = "1";
              AGENT_MAIL_GUARD_MODE = "warn";
            };
          };
        };
      });

      home.file.".pi/agent/agents/worker.md".source = lib.mkForce (pkgs.writeText "worker.md" (patchAgentModel ../../pi-extensions/agent-overrides/worker.md));
      home.file.".pi/agent/agents/planner.md".source = lib.mkForce (pkgs.writeText "planner.md" (patchAgentModel ../../pi-extensions/agent-overrides/planner.md));
      home.file.".pi/agent/agents/oracle.md".source = lib.mkForce (pkgs.writeText "oracle.md" (patchAgentModel ../../pi-extensions/agent-overrides/oracle.md));
      home.file.".pi/agent/agents/reviewer.md".source = lib.mkForce (pkgs.writeText "reviewer.md" (patchAgentModel ../../pi-extensions/agent-overrides/reviewer.md));
      home.file.".pi/agent/agents/scout.md".source = lib.mkForce (pkgs.writeText "scout.md" (patchAgentModel ../../pi-extensions/agent-overrides/scout.md));
      home.file.".pi/agent/agents/researcher.md".source = lib.mkForce (pkgs.writeText "researcher.md" (patchAgentModel ../../pi-extensions/agent-overrides/researcher.md));
      home.file.".pi/agent/agents/workstream-compounder.md".source = lib.mkForce (pkgs.writeText "workstream-compounder.md" (patchAgentModel ../../pi-extensions/agent-overrides/workstream-compounder.md));

      home.shellAliases = {
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
        pnpm
        rustup
        cargo-update
        saml2aws
        kubernetes-helm
        helm-dashboard
        fluxcd
        docker-compose
        podman-compose
        devpod
        odo
        # secretspec moved to shared-devtools.nix -- mahakala needs it too
        ripgrep
        cheat
        exercism
        fd
        dust
        duf
        procs
        sd
        tokei
        bandwhich
        grex
        hyperfine
        nerd-fonts.fira-code
        freeciv
        agent-token-dashboard
      ];

      programs.git = {
        enable = true;
        settings = {
          user.name = "Tao Hansen";
          user.email = "tao.hansen@lego.com";
          feature.manyFiles = true;
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

      # Terminal programs (delta, fzf, tmux, wezterm, btop, neovim, lf, lazygit,
      # dircolors) come from den.aspects.terminal. Only macOS overrides below.

      programs.direnv.silent = true;

      programs.eza = {
        enable = true;
        icons = "auto";
        git = true;
        extraOptions = [
          "--group-directories-first"
          "--header"
        ];
      };

      programs.bat.config.theme = "Dracula";

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

      # macOS-specific WezTerm: CMD keybindings + background blur
      programs.wezterm.extraConfig = lib.mkForce ''
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
        extensions = with pkgs; [gh-dash];
      };

      programs.topgrade = {
        enable = true;
        settings = {
          misc = {
            assume_yes = true;
            disable = [
              "nix"
              "home_manager"
              "brew_formula"
              "brew_cask"
              "bun"
              "bun_packages"
              "bob"
              "helm"
              "github_cli_extensions"
              "rustup"
              "pi"
              "claude_code"
            ];
            set_title = true;
          };
          commands = {
            # Separate steps on purpose. Attrset order puts "Flake inputs"
            # first, so inputs refresh before the deploy — but a forge outage
            # fails only its own step instead of blocking the deploy.
            "Flake inputs" = "cd ~/.config/home-manager && just update";
            "Nix-Darwin via Justfile" = "cd ~/.config/home-manager && just deploy-darwin";
          };
        };
      };

      # SSH base config (settings for *, github.com, fleet hosts) comes from
      # den.aspects.ssh. Only macOS-specific overrides here.
      programs.ssh.settings = {
        "*".AddKeysToAgent = "yes";
        "github.com".IdentityFile = "~/.ssh/my_ssh_key";
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
