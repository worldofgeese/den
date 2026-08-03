{
  den,
  gateway,
  inputs,
  ...
}: {
  den.aspects.M-02877 = {
    darwin = {
      config,
      lib,
      pkgs,
      ...
    }: let
      # Which machine's published ports to read out of the gateway aspect.
      # 8787 is container-internal here and published as 18787; on mahakala
      # the same logical port is also the host port. See gateway.json.
      entity = "M-02877";
    in {
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
        trusted-users = ["root" "dktaohan"];
        # Fetch whatever this host has already pushed with `just cachix-push`
        # instead of recompiling it. Upstream publishes no cache, so every
        # decapod bump otherwise costs a local Rust build. Note the cache cannot
        # be populated from mahakala: entries are per system and this host is
        # aarch64-darwin.
        extra-substituters = ["https://worldofgeese.cachix.org"];
        extra-trusted-public-keys = [
          "worldofgeese.cachix.org-1:Xs/BcZWj1l+kWJlD1PwsnYR+fTZC49uey77NABJZmEs="
        ];
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
        headroom-proxy = {
          serviceConfig = {
            Label = "com.headroom.proxy";
            ProgramArguments = [
              "/bin/sh"
              "-c"
              ''
                C=/opt/homebrew/bin/container
                $C system start >/dev/null 2>&1 || true
                until $C system status >/dev/null 2>&1; do sleep 2; done
                $C network create proxy-chain 2>/dev/null || true
                $C stop headroom 2>/dev/null || true
                $C rm headroom 2>/dev/null || true
                # HEADROOM_MODE (not HEADROOM_DEFAULT_MODE, which does not exist) --
                # `cache` freezes prior turns so the gateway's prefix cache keeps hitting.
                # `token` compresses harder but rewrites history, busting the cache and
                # costing more on a prefix-caching provider. The value now lives in
                # gateway.json so Guix Home cannot silently run a different mode, which
                # is exactly what it was doing. Explicit args replace the image CMD, so
                # --host/--port must be repeated here.
                #
                # HEADROOM_HTTP2=off is load-bearing, not a tuning knob. The gateway
                # speaks HTTP/2, and headroom multiplexes many streams onto one upstream
                # connection. When the gateway's LB recycled that connection it sent a
                # GOAWAY (ConnectionTerminated error_code:0 -- NO_ERROR, i.e. routine),
                # which headroom's pool did not recover from. Uvicorn defaults to a single
                # worker, so the hung upstream calls saturated the only event loop and the
                # proxy stopped answering everything -- including /livez, which touches no
                # upstream. Container status stayed `running` throughout, so nothing
                # noticed. HTTP/1.1 gives up multiplexing we do not benefit from here
                # (few, long, streaming requests) and removes the shared-connection blast
                # radius entirely.
                # -m is not optional. Measured on 2026-08-03: memory.current sat
                # at 967 MB against Apple container's 1024 MB default cap --
                # 94.5% and still climbing -- with SwapTotal 0, five minutes
                # after a restart. onnxruntime embeddings plus --memory --learn
                # plus 76k-token requests do not fit, so a large request trips
                # the kernel OOM killer. headroom is SIGKILLed before it can log
                # anything, the launchd job records exit 137, and the
                # container-runtime-linux helper is left orphaned -- which then
                # presents as the same total wedge as an upstream stall, with no
                # traceback to tell them apart.
                #
                # The value lives in gateway.json because the ~1 GB working set
                # is a property of headroom, not of this machine: mahakala would
                # OOM at the same ceiling. Only Apple container caps at 1 GB by
                # default -- podman does not -- so leaving it implicit is exactly
                # the silent cross-substrate drift that file exists to prevent.
                $C image pull ${gateway.headroom.image} && exec $C run --rm --name headroom -m ${gateway.headroom.memory} --network proxy-chain -p ${gateway.headroom.publishSpec entity} -v headroom-data:/data -e ANTHROPIC_TARGET_API_URL=${gateway.claudeUrl} -e HEADROOM_HOST=0.0.0.0 -e HEADROOM_MODE=${gateway.headroom.mode} -e HEADROOM_HTTP2=${gateway.headroom.http2} -e 'HEADROOM_STORE_URL=${gateway.headroom.storeUrl}' -e HEADROOM_SAVINGS_PATH=${gateway.headroom.savingsPath} -e HEADROOM_TELEMETRY=${gateway.headroom.telemetry} ${gateway.headroom.image} --host 0.0.0.0 --port ${toString gateway.headroom.containerPort} --memory --learn
              ''
            ];
            RunAtLoad = true;
            KeepAlive = true;
            StandardOutPath = "/tmp/headroom.log";
            StandardErrorPath = "/tmp/headroom.err";
          };
        };

        # Nothing above notices a headroom that is alive but serving nothing.
        # KeepAlive only fires when the process *dies*, and on 2026-08-03 it
        # never died: an upstream stall saturated its single uvicorn worker, so
        # every endpoint timed out -- including /livez, which touches no
        # upstream -- while `container list` still said `running`. That outage
        # ran for hours before a human noticed. HEADROOM_HTTP2=off removes the
        # trigger we hit; this removes the whole category.
        #
        # Probe /readyz, not /livez: /readyz exercises the upstream and fails
        # first. Three consecutive failures (~3 min) clears headroom's ~30s
        # model-load startup and a deploy restart without false-firing.
        #
        # Recovery is the sequence proven during that incident. Killing the
        # container-runtime-linux helper is what actually frees the container:
        # `container stop` cannot be relied on, because Apple container 1.2.0
        # fails to deliver the signal over XPC ("missing signal in xpc
        # message") and hangs forever -- which also deadlocks the KeepAlive
        # agent above on its own prestart `$C stop`. Kill the helper first so
        # that prestart line can return; only then kill a supervisor that has
        # not exited on its own.
        headroom-watchdog = {
          serviceConfig = {
            Label = "com.headroom.watchdog";
            ProgramArguments = [
              "/bin/sh"
              "-c"
              ''
                URL=${gateway.headroom.loopbackUrl entity}/readyz
                STATE=/tmp/headroom-watchdog.state
                COOLDOWN=/tmp/headroom-watchdog.cooldown
                THRESHOLD=3

                if /usr/bin/curl -sf -o /dev/null -m 10 "$URL"; then
                  rm -f "$STATE"
                  exit 0
                fi

                FAILS=$(cat "$STATE" 2>/dev/null || echo 0)
                FAILS=$((FAILS + 1))
                echo "$FAILS" > "$STATE"
                echo "$(/bin/date -Iseconds) /readyz failed ($FAILS/$THRESHOLD)"
                [ "$FAILS" -lt "$THRESHOLD" ] && exit 0

                # Never thrash: a headroom that is broken rather than wedged
                # would otherwise be restarted every three minutes forever.
                NOW=$(/bin/date +%s)
                LAST=$(cat "$COOLDOWN" 2>/dev/null || echo 0)
                if [ $((NOW - LAST)) -lt 600 ]; then
                  echo "$(/bin/date -Iseconds) still failing, but within 10m cooldown -- not acting"
                  exit 0
                fi

                # Match the helper for *this* container only, and anchor on the
                # command path: this agent's own `/bin/sh -c <script>` process
                # carries the whole script -- including these very strings -- in
                # its command line, so a substring search would match the
                # watchdog itself and kill the wrong pid. $2 is the executable,
                # which is /bin/sh for this agent and /usr/bin/awk for the
                # search. Both the --root path and --uuid carry the container
                # name, so phoenix and local-model-proxy cannot be hit either.
                HELPER=$(/bin/ps -Ao pid=,command= | /usr/bin/awk '$2 ~ /container-runtime-linux$/ && index($0,"containers/headroom") {print $1; exit}')
                if [ -n "$HELPER" ]; then
                  echo "$(/bin/date -Iseconds) recovering: killing wedged headroom VM helper pid $HELPER"
                  kill -9 "$HELPER" 2>/dev/null || true
                fi

                # `container run --rm` normally exits once its container is
                # gone; if it has not, it is the orphan case from the incident.
                sleep 5
                SUP=$(/bin/ps -Ao pid=,command= | /usr/bin/awk '$2 ~ /container$/ && index($0,"--name headroom") {print $1; exit}')
                if [ -n "$SUP" ]; then
                  echo "$(/bin/date -Iseconds) supervisor pid $SUP did not exit; killing it too"
                  kill -9 "$SUP" 2>/dev/null || true
                fi

                echo "$NOW" > "$COOLDOWN"
                rm -f "$STATE"
                echo "$(/bin/date -Iseconds) recovery done; KeepAlive will recreate headroom"
              ''
            ];
            RunAtLoad = true;
            StartInterval = 60;
            StandardOutPath = "/tmp/headroom-watchdog.log";
            StandardErrorPath = "/tmp/headroom-watchdog.err";
          };
        };

        phoenix = {
          serviceConfig = {
            Label = "com.phoenix";
            ProgramArguments = [
              "/bin/sh"
              "-c"
              ''
                C=/opt/homebrew/bin/container
                $C system start >/dev/null 2>&1 || true
                until $C system status >/dev/null 2>&1; do sleep 2; done
                $C network create proxy-chain 2>/dev/null || true
                $C stop phoenix 2>/dev/null || true
                $C rm phoenix 2>/dev/null || true
                $C image pull ${gateway.phoenix.image} && exec $C run --rm --name phoenix --network proxy-chain -p ${gateway.phoenix.publishSpec entity} -e PHOENIX_DEFAULT_RETENTION_POLICY_DAYS=30 -e PHOENIX_PROJECT_NAME=local-model-proxy ${gateway.phoenix.image}
              ''
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
              "/bin/sh"
              "-c"
              # Apple's container tool provides no inter-container DNS, and container
              # IPs are reassigned on every restart -- headroom coming back on a new
              # IP left a stale MPS_BASE_URL here, 502ing every request while launchd
              # still reported both services healthy. The network gateway is stable
              # (it outlives individual containers), so reach headroom and phoenix
              # through their published host ports rather than their own IPs.
              ''
                C=/opt/homebrew/bin/container
                $C system start >/dev/null 2>&1 || true
                until $C system status >/dev/null 2>&1; do sleep 2; done
                $C network create proxy-chain 2>/dev/null
                $C stop local-model-proxy 2>/dev/null
                $C rm local-model-proxy 2>/dev/null

                GATEWAY_IP=""
                for i in $(seq 1 30); do
                  GATEWAY_IP=$($C network inspect proxy-chain 2>/dev/null \
                    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['status']['ipv4Gateway'])" 2>/dev/null)
                  [ -n "$GATEWAY_IP" ] && break
                  sleep 2
                done
                if [ -z "$GATEWAY_IP" ]; then
                  echo "FATAL: could not resolve proxy-chain gateway; exiting for KeepAlive relaunch" >&2
                  exit 1
                fi

                # Gate on /livez, not /health: /health also probes upstream and hangs
                # when headroom's connection pool wedges, which would block startup
                # even while headroom is otherwise serving.
                HEADROOM_READY=false
                for i in $(seq 1 30); do
                  if /usr/bin/curl -sf -m 2 http://''${GATEWAY_IP}:${toString (gateway.headroom.port entity)}/livez >/dev/null 2>&1; then
                    HEADROOM_READY=true
                    break
                  fi
                  sleep 2
                done
                if [ "$HEADROOM_READY" != true ]; then
                  echo "FATAL: headroom did not become live; exiting for KeepAlive relaunch" >&2
                  exit 1
                fi

                $C image pull ${gateway.proxy.image}
                exec $C run --rm --name local-model-proxy --network proxy-chain -p ${gateway.proxy.publishSpec entity} \
                  -e PROXY_HOST=0.0.0.0 -e PROXY_PORT=${toString gateway.proxy.containerPort} \
                  -e MPS_BASE_URL="http://''${GATEWAY_IP}:${toString (gateway.headroom.port entity)}" \
                  -e LOG_LEVEL=INFO -e PRICING_PLAN=lego \
                  -e OTEL_PROJECT_NAME=local-model-proxy \
                  -e OTEL_SERVICE_NAME=local-model-proxy \
                  -e OTEL_EXPORTER_OTLP_ENDPOINT="http://''${GATEWAY_IP}:${toString (gateway.phoenix.port entity)}" \
                  ${gateway.proxy.image}
              ''
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
              # No ANTHROPIC_* here on purpose: Claude Code's ~/.claude/settings.json
              # `env` block overrides the inherited environment, so anything set here
              # is silently ignored. Gateway URL, token, and model IDs live there.
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
          "gascity"
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
