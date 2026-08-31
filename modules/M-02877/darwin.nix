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
      pythonWithNacl = pkgs.python3.withPackages (pythonPackages: [pythonPackages.pynacl]);

      # The ambient team-Signet tunnel.
      #
      # projects/aws-signet in LEGO/devrel-infra has no public listener: the
      # daemon is reached over IAM-authenticated Systems Manager port forwarding.
      # This keeps that tunnel up without anyone thinking about it, and it is
      # deliberately self-contained rather than calling the repository's
      # scripts/connect.sh, so the agent does not break when a checkout moves.
      # The portable equivalent for teammates who do not run Nix is
      # `scripts/install-tunnel.sh` in that project; the two must stay in step.
      signetTeamTunnel = pkgs.writeShellApplication {
        name = "signet-team-tunnel";
        runtimeInputs = [pkgs.awscli2 pkgs.jq pkgs.ssm-session-manager-plugin];
        text = ''
          set -eu
          region="''${AWS_REGION:-eu-west-1}"
          stage="''${SIGNET_STAGE:-production}"
          port="''${SIGNET_LOCAL_PORT:-3860}"

          # Wait for credentials rather than crash-looping against them. The
          # account's SSO-Admin role caps a session at one hour, and the LEGO CLI
          # credential process re-issues silently only while the Azure session
          # lives; when that lapses a human has to sign in, and there is nothing
          # useful to do until they do.
          until aws sts get-caller-identity >/dev/null 2>&1; do sleep 60; done

          # 3850 is where a personal Signet listens, so the team tunnel takes
          # 3860. Refuse to bind over anything already there: adopting a local
          # daemon would silently point every agent at one laptop's workspace.
          if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
            echo "port $port already in use; not starting a second tunnel" >&2
            sleep 300
            exit 1
          fi

          # Wait inside one invocation rather than exiting for launchd to retry.
          # Exiting was measured costing about four minutes of downtime after a
          # task replacement: the guard slept, exited, and then each restart found
          # the new task's exec agent still PENDING and exited again. Polling here
          # reconnects as soon as the agent is ready.
          #
          # The target is resolved on every pass because it embeds the container
          # runtime id, which changes whenever ECS replaces the task.
          target=""
          while [ -z "$target" ]; do
            cluster_arn=$(aws resourcegroupstaggingapi get-resources --region "$region" \
              --resource-type-filters ecs:cluster \
              --tag-filters "Key=sst:app,Values=aws-signet" "Key=sst:stage,Values=$stage" \
              --query 'ResourceTagMappingList[0].ResourceARN' --output text 2>/dev/null || true)
            if [ -z "$cluster_arn" ] || [ "$cluster_arn" = "None" ]; then
              sleep 30
              continue
            fi
            cluster="''${cluster_arn##*/}"

            task=$(aws ecs list-tasks --region "$region" --cluster "$cluster" \
              --desired-status RUNNING --query 'taskArns[0]' --output text 2>/dev/null || true)
            if [ -z "$task" ] || [ "$task" = "None" ]; then
              # The daemon exits 0 when it cannot take its workspace lock, so an
              # absent task can mean a refused start rather than a deploy.
              sleep 10
              continue
            fi

            # Two queries rather than one line split by a heredoc: a heredoc
            # terminator inside a Nix indented string only lands in column 1
            # because Nix strips the common indentation, which is too fragile a
            # thing to rely on.
            agent_state=$(aws ecs describe-tasks --region "$region" --cluster "$cluster" \
              --tasks "$task" --query 'tasks[0].containers[0].managedAgents[0].lastStatus' \
              --output text 2>/dev/null || true)
            runtime_id=$(aws ecs describe-tasks --region "$region" --cluster "$cluster" \
              --tasks "$task" --query 'tasks[0].containers[0].runtimeId' \
              --output text 2>/dev/null || true)
            # The exec agent takes a couple of minutes to reach RUNNING after a
            # task starts, and start-session fails until it does. Waiting here is
            # what makes a deploy self-heal without anyone watching.
            if [ "$agent_state" != "RUNNING" ] || [ -z "$runtime_id" ] || [ "$runtime_id" = "None" ]; then
              sleep 10
              continue
            fi
            target="ecs:''${cluster}_''${task##*/}_''${runtime_id}"
          done

          # exec, so launchd supervises the session itself and KeepAlive
          # reconnects the moment it ends.
          exec aws ssm start-session --region "$region" \
            --target "$target" \
            --document-name "Signet-$stage-Daemon" \
            --parameters "localPortNumber=$port"
        '';
      };
      signetReadLegoSecret = pkgs.writeTextFile {
        name = "signet-read-lego-secret";
        destination = "/bin/signet-read-lego-secret";
        executable = true;
        text = ''
          #!${pythonWithNacl}/bin/python3
          import base64
          import hashlib
          import json
          import os
          import sys

          from nacl.secret import SecretBox

          secret_dir = os.path.expanduser("~/.agents/.secrets")
          with open(os.path.join(secret_dir, ".machine-id"), encoding="utf-8") as file:
              machine_id = file.read().strip()
          with open(os.path.join(secret_dir, "secrets.enc"), encoding="utf-8") as file:
              store = json.load(file)

          if store.get("version") != 1 or store.get("provider") == "native-keyring":
              raise RuntimeError("Signet secret store is not the portable fallback format")
          entry = store.get("secrets", {}).get("LEGO_GENAI_TOKEN")
          if not entry:
              raise RuntimeError("LEGO_GENAI_TOKEN is absent from the Signet secret store")

          key = hashlib.blake2b(f"signet:secrets:{machine_id}".encode(), digest_size=32).digest()
          plaintext = SecretBox(key).decrypt(base64.b64decode(entry["ciphertext"], validate=True))
          sys.stdout.buffer.write(plaintext)
        '';
      };
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

        # Containerised Signet daemon. Every flag
        # here diverges from the first-party compose on purpose: that one is
        # server-shaped (Caddy in front, 0.0.0.0 published, named volume, team
        # auth) and a single-user workstation needs none of it.
        #
        # Three of them are load-bearing rather than taste:
        #
        #   --unshare-netns -- distrobox otherwise passes `--network host`, and
        #     on macOS "host" is the podman VM, so a published port never
        #     reaches the mac and `-p` silently does nothing. Unsharing the net
        #     namespace puts the container on the normal bridge, which is the
        #     only way a loopback 3850 can exist on this machine at all.
        #   --volume /var/folders -- distrobox-enter forwards the *entire* host
        #     environment, macOS TMPDIR=/var/folders/... included. Without the
        #     mount every invocation dies inside materializeEmbeddedAssetTree
        #     with EACCES mkdir '/var/folders'. Mounting it at the identical
        #     path is the same trick as distrobox's own $HOME mount, and it is
        #     what keeps host-indexed paths resolving inside the container.
        #   SIGNET_DAEMON_ENTRYPOINT=0 -- the image sets it to 1 globally and
        #     signet routes *any* invocation to the daemon while it is 1, so
        #     left alone the exported `signet status` becomes a second daemon.
        #     Only the exec line below re-enables it, for its own process.
        #
        # `distrobox assemble` would be the declarative way to say this and is
        # unusable here: its ini parser runs sed 's/\s*$//g', BSD sed reads \s
        # as a literal s, and every value silently loses a trailing "s"
        # (/data/agents arrives as /data/agent). The create call is the manifest.
        signet-container = {
          serviceConfig = {
            Label = "com.dktaohan.signet-container";
            ProgramArguments = [
              "/bin/sh"
              "-c"
              ''
                set -eu
                export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
                home=${config.users.users.dktaohan.home}
                bin=$home/.local/bin

                # Podman's macOS VM shares /Users, /private, /var/folders and
                # /etc/containers, and nothing else. distrobox derives
                # distrobox-init/-export/-host-exec from dirname($0) and
                # bind-mounts them into the container, so driving Homebrew's
                # copy asks podman to mount an /opt/homebrew path the VM cannot
                # see. Real copies under $HOME are visible at an identical path
                # inside the VM; symlinks are not, they still resolve to
                # /opt/homebrew. Refreshing them on every start is also what
                # keeps them current after a `brew upgrade distrobox`, and the
                # exported launcher hardcodes the distrobox-enter it was
                # generated with, so this is the path every host `signet` call
                # goes through.
                mkdir -p "$bin"
                for f in /opt/homebrew/opt/distrobox/bin/distrobox*; do
                  cp -f "$f" "$bin/$(basename "$f")"
                done
                chmod +x "$bin"/distrobox*

                # `machine inspect` can report a stale "running" state after an
                # unclean host shutdown, and `machine start` then refuses, so
                # trusting that state once leaves this loop spinning forever
                # against a VM that never boots. Drive off real reachability:
                # `machine start` blocks until the VM answers, and `stop`
                # reconciles a stale state (a no-op when already stopped).
                until podman info >/dev/null 2>&1; do
                  podman machine stop >/dev/null 2>&1 || true
                  podman machine start || sleep 5
                done

                podman container exists signet ||
                  DBX_CONTAINER_MANAGER=podman "$bin/distrobox" create --yes --no-entry --unshare-netns \
                    --name signet \
                    --image ghcr.io/signet-ai/signet:0.214.27 \
                    --volume "$home/.agents:/data/agents" \
                    --volume /var/folders:/var/folders \
                    --additional-flags "--publish 127.0.0.1:3850:3850 --env SIGNET_DAEMON_ENTRYPOINT=0 --env SIGNET_PATH=/data/agents --env SIGNET_BIND=0.0.0.0 --env SIGNET_PORT=3850"

                # First enter runs distrobox-init (user, sudo, mounts, ~3 min);
                # every later one is a no-op that just starts the container.
                "$bin/distrobox-enter" --no-tty --name signet -- true

                # Distrobox owns the host launcher; invoke the helper through
                # its stable home-directory mount. The transient /usr/bin
                # injection disappears before a no-TTY command can exec it.
                # --clean-path prevents Linux from resolving host Mach-O tools.
                "$bin/distrobox-enter" --no-tty --name signet -- \
                  "$bin/distrobox-export" --bin /app/bin/signet \
                    --export-path "$bin" --enter-flags "--clean-path"

                # GraphIQ's verified installer reads GitHub release digests
                # with jq. Its awk fallback uses a non-portable \s regexp and
                # fails closed on this Debian image. Install jq only when a
                # newly-created box lacks it.
                if ! "$bin/distrobox-enter" --no-tty --name signet -- test -x /usr/bin/jq; then
                  "$bin/distrobox-enter" --no-tty --name signet -- \
                    sudo env DEBIAN_FRONTEND=noninteractive apt-get update
                  "$bin/distrobox-enter" --no-tty --name signet -- \
                    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y jq
                fi

                # Host $HOME is shared into distrobox and contains a Mach-O
                # graphiq binary. Install the checked Linux build in preserved
                # workspace storage, then expose it on the container's clean
                # FHS PATH. Keeping HOME unchanged for the daemon preserves
                # host transcript discovery under ~/.claude.
                graphiq=/data/agents/.container-home/.local/bin/graphiq
                if ! "$bin/distrobox-enter" --no-tty --name signet -- test -x "$graphiq"; then
                  "$bin/distrobox-enter" --no-tty --clean-path \
                    --additional-flags "--env HOME=/data/agents/.container-home" \
                    --name signet -- /app/bin/signet graphiq install
                  "$bin/distrobox-enter" --no-tty --name signet -- test -x "$graphiq"
                fi
                "$bin/distrobox-enter" --no-tty --name signet -- \
                  sudo ln -sf "$graphiq" /usr/local/bin/graphiq

                # A host restart kills the daemon without releasing its lock,
                # and the recorded pid belongs to the container's dead pid
                # namespace, where the number is reusable after a restart, so
                # the next daemon refuses to start. launchd owns the only
                # instance: when nothing answers the published port, the lock
                # is stale by definition.
                if ! curl -sf --max-time 2 http://127.0.0.1:3850/health >/dev/null 2>&1; then
                  rm -f "$home/.agents/.daemon/daemon.lock" "$home/.agents/.daemon/pid"
                fi

                # Clean PATH excludes host Mach-O binaries while retaining the
                # normal host HOME for transcript and source paths.
                exec "$bin/distrobox-enter" --no-tty --clean-path --name signet -- \
                  env SIGNET_DAEMON_ENTRYPOINT=1 /app/bin/signet
              ''
            ];
            RunAtLoad = true;
            # Restart daemon failures; leave intentional clean exits stopped.
            KeepAlive = {SuccessfulExit = false;};
            ProcessType = "Background";
            StandardOutPath = "${config.users.users.dktaohan.home}/.local/state/signet-container.log";
            StandardErrorPath = "${config.users.users.dktaohan.home}/.local/state/signet-container.log";
          };
        };

        # Team Signet, always reachable on http://127.0.0.1:3860.
        #
        # KeepAlive is unconditional rather than SuccessfulExit = false, because a
        # clean end here is not a reason to stop: an SSM session ends whenever ECS
        # replaces the task, and the point of this agent is that nobody has to
        # notice. The script sleeps before failing on a missing prerequisite, so a
        # missing credential or a stopped service costs one wait rather than a hot
        # restart loop; ThrottleInterval is the floor under that.
        #
        # This does not repoint any tool at the team daemon. The personal Signet
        # on 3850 keeps its own workspace, and switching an agent over is one
        # explicit `SIGNET_DAEMON_URL=http://127.0.0.1:3860`.
        signet-team-tunnel = {
          serviceConfig = {
            Label = "com.dktaohan.signet-team-tunnel";
            ProgramArguments = ["${signetTeamTunnel}/bin/signet-team-tunnel"];
            EnvironmentVariables = {
              # Any profile whose credential_process is the LEGO CLI works; that
              # is the one path that rotates without re-prompting for a second
              # factor every hour.
              AWS_PROFILE = "bts-devrel";
              AWS_REGION = "eu-west-1";
              HOME = config.users.users.dktaohan.home;
            };
            RunAtLoad = true;
            KeepAlive = true;
            ThrottleInterval = 30;
            ProcessType = "Background";
            StandardOutPath = "${config.users.users.dktaohan.home}/.local/state/signet-team-tunnel.log";
            StandardErrorPath = "${config.users.users.dktaohan.home}/.local/state/signet-team-tunnel.log";
          };
        };

        # Signet's `anthropic` executor sends its credential as `x-api-key`
        # unless the key literally contains "sk-ant-oat" (isOAuthToken in the
        # bundled pi-ai client). The gateway only accepts `Authorization:
        # Bearer`, so a virtual key 401s. This shim is the smallest thing that
        # closes that gap: loopback-only, rewrites the auth header, forwards
        # everything else untouched including SSE.
        #
        # It matters because dreaming -- the only automatic semantic writer --
        # cannot use an acpx target at all: resolveMcpEntrypoint() derives its
        # MCP stdio path from import.meta.url, which inside the compiled binary
        # is /$bunfs/mcp-stdio.js and does not exist. A non-acpx executor skips
        # that binding entirely, so a direct gateway target is the only route
        # dreaming has from the compiled container image.
        signet-gateway-shim = {
          serviceConfig = {
            Label = "com.dktaohan.signet-gateway-shim";
            ProgramArguments = [
              "${pkgs.bun}/bin/bun"
              "${config.users.users.dktaohan.home}/.local/libexec/signet-gateway-shim.mjs"
            ];
            EnvironmentVariables = {
              HOME = config.users.users.dktaohan.home;
              SHIM_PORT = "3851";
              SHIM_UPSTREAM = gateway.claudeUrl;
              # `secret exec` redacts captured stdout, so it cannot feed a
              # credential command. This fixed-purpose reader decrypts only
              # LEGO_GENAI_TOKEN from the same portable workspace store.
              # The shim receives the value over a private child-process pipe.
              SHIM_TOKEN_COMMAND = "${signetReadLegoSecret}/bin/signet-read-lego-secret";
            };
            RunAtLoad = true;
            KeepAlive = true;
            ProcessType = "Background";
            StandardOutPath = "${config.users.users.dktaohan.home}/.local/state/signet-gateway-shim.log";
            StandardErrorPath = "${config.users.users.dktaohan.home}/.local/state/signet-gateway-shim.log";
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
        caskArgs.appdir = "/Users/dktaohan/Applications";
        onActivation.autoUpdate = true;
        onActivation.upgrade = true;
        onActivation.cleanup = "none"; # TODO: restore to "zap" once nix-darwin#1774 is merged (Homebrew broke --cleanup without --force)
        masApps = {
          "Microsoft To Do" = 1274495053;
          "Flow" = 1423210932;
        };
        brews = [
          "podman"
          # Signet's daemon runs in a podman container via distrobox; the
          # signet-container agent copies these scripts under $HOME because the
          # podman VM cannot see /opt/homebrew.
          "distrobox"
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
          "claude"
          "d12frosted/emacs-plus/emacs-plus-app"
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
          "chatgpt"
          "visual-studio-code"
          "visual-studio-code@insiders"
          "monokle"
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
            name = "d12frosted/emacs-plus";
            trusted = true;
          }
          {
            name = "lego/tap";
            clone_target = "git@github.com:LEGO/homebrew-tap.git";
          }
        ];
      };
    };
  };
}
