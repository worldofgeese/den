{
  den,
  inputs,
  ...
}: {
  den.aspects.M-02877 = {
    darwin = {
      config,
      lib,
      pkgs,
      ...
    }: {
      home-manager.useUserPackages = true;
      home-manager.backupFileExtension = "hm-bak";

      nix.enable = true;
      nixpkgs.config.allowUnfree = true;
      nixpkgs.overlays = [
        (final: prev: {
          inherit
            (prev.lixPackageSets.latest)
            nixpkgs-review
            nix-eval-jobs
            nix-fast-build
            colmena
            ;
        })
      ];

      nix.package = pkgs.lixPackageSets.latest.lix;
      nix.channel.enable = false;
      nix.settings = {
        experimental-features = ["nix-command" "flakes" "auto-allocate-uids"];
        extra-platforms = [];
        warn-dirty = false;
        auto-optimise-store = true;
        extra-deprecated-features = ["or-as-identifier"];
      };

      users.users.dktaohan.home = "/Users/dktaohan";
      system.primaryUser = "dktaohan";

      programs.zsh = {
        enable = true;
        enableCompletion = true;
        enableAutosuggestions = true;
        enableSyntaxHighlighting = true;
        interactiveShellInit = ''
          autoload -Uz compinit && compinit
          eval "$(${pkgs.saml2aws}/bin/saml2aws --completion-script-zsh)"
          eval "$(${pkgs.eksctl}/bin/eksctl completion zsh)"
        '';
      };

      # --- LaunchAgents (managed by nix-darwin) ---
      launchd.user.agents = {
        # Podman machine must start before container agents
        podman-machine = {
          serviceConfig = {
            Label = "com.podman.machine.default";
            ProgramArguments = ["/opt/homebrew/bin/podman" "machine" "start"];
            RunAtLoad = true;
            StandardOutPath = "/tmp/podman-machine-start.log";
            StandardErrorPath = "/tmp/podman-machine-start.err";
          };
        };

        headroom-proxy = {
          serviceConfig = {
            Label = "com.headroom.proxy";
            ProgramArguments = [
              "/opt/homebrew/bin/podman"
              "run"
              "--replace"
              "--rm"
              "--pull"
              "always"
              "--name"
              "headroom"
              "--network"
              "proxy-chain"
              "-p"
              "8787:8787"
              "-v"
              "headroom-data:/data"
              "-e"
              "ANTHROPIC_TARGET_API_URL=https://models.assistant.legogroup.io/claude"
              "-e"
              "HEADROOM_HOST=0.0.0.0"
              "-e"
              "HEADROOM_DEFAULT_MODE=optimize"
              "-e"
              "HEADROOM_STORE_URL=sqlite:////data/headroom.db"
              "-e"
              "HEADROOM_SAVINGS_PATH=/data/proxy_savings.json"
              "-e"
              "HEADROOM_TELEMETRY=off"
              "ghcr.io/chopratejas/headroom:latest"
            ];
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath = "/tmp/headroom.log";
            StandardErrorPath = "/tmp/headroom.err";
          };
        };

        phoenix = {
          serviceConfig = {
            Label = "com.phoenix";
            ProgramArguments = [
              "/opt/homebrew/bin/podman"
              "run"
              "--replace"
              "--rm"
              "--pull"
              "always"
              "--name"
              "phoenix"
              "--network"
              "proxy-chain"
              "-p"
              "6006:6006"
              "-e"
              "PHOENIX_DEFAULT_RETENTION_POLICY_DAYS=30"
              "-e"
              "PHOENIX_PROJECT_NAME=local-model-proxy"
              "docker.io/arizephoenix/phoenix:latest"
            ];
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath = "/tmp/phoenix.log";
            StandardErrorPath = "/tmp/phoenix.err";
          };
        };

        local-model-proxy = {
          serviceConfig = {
            Label = "com.local-model-proxy";
            ProgramArguments = [
              "/opt/homebrew/bin/podman"
              "run"
              "--replace"
              "--rm"
              "--pull"
              "always"
              "--name"
              "local-model-proxy"
              "--network"
              "proxy-chain"
              "-p"
              "8788:8788"
              "-e"
              "PROXY_HOST=0.0.0.0"
              "-e"
              "PROXY_PORT=8788"
              "-e"
              "MPS_BASE_URL=http://headroom:8787"
              "-e"
              "LOG_LEVEL=INFO"
              "-e"
              "PRICING_PLAN=lego"
              "-e"
              "OTEL_PROJECT_NAME=local-model-proxy"
              "-e"
              "OTEL_SERVICE_NAME=local-model-proxy"
              "-e"
              "OTEL_EXPORTER_OTLP_ENDPOINT=http://phoenix:6006"
              "ghcr.io/lego/local-model-proxy:latest"
            ];
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath = "/tmp/local-model-proxy.log";
            StandardErrorPath = "/tmp/local-model-proxy.err";
          };
        };

        gascity-supervisor = {
          serviceConfig = {
            Label = "com.gascity.supervisor";
            ProgramArguments = ["/opt/homebrew/bin/gc" "supervisor" "run"];
            RunAtLoad = true;
            KeepAlive = {
              Crashed = true;
              SuccessfulExit = false;
            };
            EnvironmentVariables = {
              GC_HOME = "/Users/dktaohan/.gc";
              HOME = "/Users/dktaohan";
              LANG = "en_US.UTF-8";
              USER = "dktaohan";
              LOGNAME = "dktaohan";
              SHELL = "/bin/zsh";
              XDG_CONFIG_HOME = "/Users/dktaohan/.config";
              XDG_STATE_HOME = "/Users/dktaohan/.local/state";
              GC_SUPERVISOR_PRESERVE_SESSIONS_ON_SIGNAL = "1";
              ANTHROPIC_BASE_URL = "https://models.assistant.legogroup.io/claude";
              ANTHROPIC_DEFAULT_HAIKU_MODEL = "anthropic.claude-haiku-4-5-20251001-v1:0";
              ANTHROPIC_DEFAULT_OPUS_MODEL = "anthropic.claude-opus-4-6-v1";
              ANTHROPIC_DEFAULT_SONNET_MODEL = "anthropic.claude-sonnet-4-6";
              CLAUDE_CODE_EFFORT_LEVEL = "MAX";
              PATH = "/Users/dktaohan/.local/bin:/Users/dktaohan/bin:/opt/homebrew/bin:/etc/profiles/per-user/dktaohan/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Users/dktaohan/.bun/bin:/opt/homebrew/sbin";
            };
            StandardOutPath = "/Users/dktaohan/.gc/supervisor.log";
            StandardErrorPath = "/Users/dktaohan/.gc/supervisor.log";
          };
        };

        nanoclaw-container-runtime = {
          serviceConfig = {
            Label = "com.nanoclaw.container-runtime";
            ProgramArguments = ["/opt/homebrew/bin/container" "system" "start"];
            WorkingDirectory = "/Users/dktaohan";
            RunAtLoad = true;
            KeepAlive = false;
            EnvironmentVariables = {
              PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin";
              HOME = "/Users/dktaohan";
            };
            StandardOutPath = "/Users/dktaohan/nanoclaw/logs/container-runtime.log";
            StandardErrorPath = "/Users/dktaohan/nanoclaw/logs/container-runtime.log";
          };
        };

        nanoclaw = {
          serviceConfig = {
            Label = "com.nanoclaw";
            ProgramArguments = [
              "/usr/bin/caffeinate"
              "-s"
              "/etc/profiles/per-user/dktaohan/bin/node"
              "/Users/dktaohan/nanoclaw/dist/index.js"
            ];
            WorkingDirectory = "/Users/dktaohan/nanoclaw";
            RunAtLoad = true;
            KeepAlive = true;
            EnvironmentVariables = {
              PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/Users/dktaohan/.local/bin";
              HOME = "/Users/dktaohan";
            };
            StandardOutPath = "/Users/dktaohan/nanoclaw/logs/nanoclaw.log";
            StandardErrorPath = "/Users/dktaohan/nanoclaw/logs/nanoclaw.error.log";
          };
        };
      };

      security.pam.services.sudo_local.touchIdAuth = true;
      security.pam.services.sudo_local.reattach = true;
      security.sudo.extraConfig = ''
        Defaults env_keep += "HOMEBREW_GITHUB_API_TOKEN"
        dktaohan ALL=(root) NOPASSWD: /run/current-system/sw/bin/darwin-rebuild switch *
      '';

      system.stateVersion = 5;
      system.defaults = {
        CustomUserPreferences = {
          "com.apple.desktopservices" = {
            DSDontWriteNetworkStores = true;
            DSDontWriteUSBStores = true;
          };
        };
        screencapture.location = "~/Downloads";
        finder.AppleShowAllFiles = true;
      };

      system.activationScripts.preActivation.text = ''
        if [ -z "''${HOMEBREW_GITHUB_API_TOKEN:-}" ]; then
          if token="$(sudo --user=${lib.escapeShellArg config.homebrew.user} --set-home sh -lc 'cd ${inputs.self} && ${pkgs.secretspec}/bin/secretspec get HOMEBREW_GITHUB_API_TOKEN' 2>/dev/null)"; then
            export HOMEBREW_GITHUB_API_TOKEN="$token"
          elif token="$(sudo --user=${lib.escapeShellArg config.homebrew.user} --set-home ${pkgs.github-cli}/bin/gh auth token 2>/dev/null)"; then
            export HOMEBREW_GITHUB_API_TOKEN="$token"
          fi
        fi
      '';

      homebrew = {
        enable = true;
        global.autoUpdate = true;
        onActivation.autoUpdate = true;
        onActivation.upgrade = true;
        onActivation.cleanup = "none"; # TODO: restore to "zap" once nix-darwin#1774 is merged (Homebrew broke --cleanup without --force)
        masApps = {
          "Microsoft To Do" = 1274495053;
          "Flow" = 1423210932;
        };
        brews = [
          "podman"
          "aws-nuke"
          "azure-cli"
          "pulumi"
          "container"
          "jira-cli"
          "rtk"
          "atlassian/acli/acli"
          "lego/tap/bob-cli"
          "lego/tap/mdc"
        ];
        casks = [
          "zed"
          "github-copilot-app"
          "jordanbaird-ice"
          "alt-tab"
          "loop"
          "neardrop"
          "raycast"
          "logseq"
          "notunes"
          "fork"
          "keycastr"
          "devpod"
          "dotnet-sdk"
          "adobe-acrobat-reader"
          "jetbrains-toolbox"
          "background-music"
          "secretive"
          "aerospace"
          "cursor"
          "chatgpt"
          "visual-studio-code"
          "visual-studio-code@insiders"
          "monokle"
          "codex-app"
          "genai-menu"
        ];
        taps = [
          "atlassian/homebrew-acli"
          "grishka/grishka"
          "mrkai77/cask"
          "nikitabobko/tap"
          "pulumi/tap"
          "ankitpokhrel/jira-cli"
          {
            name = "lego/tap";
            clone_target = "git@github.com:LEGO/homebrew-tap.git";
          }
        ];
      };
    };
  };
}
