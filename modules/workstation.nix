{
  den,
  inputs,
  ...
}: {
  den.aspects.workstation = {
    includes = [
      den.aspects.sharedDevtools
      den.aspects.terminal
      den.aspects.doom-emacs
    ];
    homeManager = {
      pkgs,
      lib,
      ...
    }: {
      nixpkgs.overlays = [
        (final: prev: {
          ewm = inputs.ewm.packages.${pkgs.stdenv.hostPlatform.system}.default;
          # Upstream's package.nix only forces $out/opt into the launcher
          # script; it never sets QT_QPA_PLATFORM. On Wayland sessions Qt
          # then probes for its "wayland" platform plugin first, but the
          # binary ships only the xcb plugin, so any launch path that
          # doesn't happen to export QT_QPA_PLATFORM=xcb itself (desktop
          # launchers, the packaged share/applications entry, systemd
          # xdg-autostart units) fails silently before a window or tray
          # icon ever appears. Baking the override into the wrapped
          # `synology-drive` binary -- instead of duplicating it in every
          # .desktop Exec= line -- makes every entry point behave the same.
          # QTCOMPOSE silences the unrelated "Could not find a location of
          # the system's Compose files" warning by pointing Qt at the X11
          # Compose tables libX11 already ships (dead-key/compose input
          # only; unrelated to launching).
          synology-drive-client = let
            qtWrapped = prev.synology-drive-client.overrideAttrs (old: {
              nativeBuildInputs = (old.nativeBuildInputs or []) ++ [prev.makeWrapper];
              postFixup = ''
                ${old.postFixup or ""}
                wrapProgram $out/bin/synology-drive \
                  --set QT_QPA_PLATFORM xcb \
                  --set QTCOMPOSE "${prev.libx11}/share/X11/locale"
              '';
            });
            # cloud-drive-ui shells out to /bin/cat, /usr/bin/awk,
            # /sbin/udevadm and /sbin/ifconfig by hardcoded absolute path
            # (verified: those strings live in the compiled binary, not a
            # patchable script) for device/network identification. None of
            # those paths exist on Guix System, so every call failed with
            # "No such file or directory" and those code paths silently
            # no-op'd. buildFHSEnv, not a system-wide /bin,/sbin shim,
            # because it only affects this one derivation's own bwrap
            # sandbox: /usr/bin, /bin (-> /usr/bin) and /sbin (-> /usr/sbin)
            # get a synthetic tree built from the four targetPkgs below,
            # while $HOME, /run (so $XDG_RUNTIME_DIR and the D-Bus session
            # socket), /tmp and /dev keep passing through from the real
            # host -- confirmed by hand: daemon/UI/tray and the sync data
            # dir under ~/.SynologyDrive all still worked identically after
            # wrapping, and bwrap itself was verified working on this
            # kernel first, standalone, before wiring it in here.
            fhsWrapped = prev.buildFHSEnv {
              name = "synology-drive";
              targetPkgs = pkgs: [pkgs.coreutils pkgs.gawk pkgs.nettools pkgs.systemd];
              runScript = "${qtWrapped}/bin/synology-drive";
            };
          in
            prev.runCommand qtWrapped.name {
              pname = qtWrapped.pname;
              version = qtWrapped.version;
              meta = qtWrapped.meta;
            } ''
              mkdir -p $out
              cp -rs ${qtWrapped}/* $out/
              # cp -rs preserves the read-only store source's directory
              # mode on $out/bin; without this, `rm` below fails with
              # "Permission denied" (verified: removing this line broke
              # the build).
              chmod u+w $out/bin
              rm -f $out/bin/synology-drive
              ln -s ${fhsWrapped}/bin/synology-drive $out/bin/synology-drive
            '';
        })
      ];
      # Linux workstation-specific packages (shared tools come from shared-devtools)
      home.packages =
        (with pkgs; [
          ewm
          brush
          gnomeExtensions.all-in-one-clipboard
          wl-clipboard
          wl-clip-persist
          gopass
          isort
          nixfmt
          devbox
          openshift
          kubectl-tree
          kubie
          krew
          kubernetes-helm # consolidated from Guix Home
          kind # consolidated from Guix Home
          sops
          httpie
          # yt-dlp consolidated to Guix Home (Bordeaux substitute available)
          dockfmt
          synology-drive-client
          python-launcher
          kn
          megasync
          agent-browser
          beeper
          ollama # embedding server for crucible semantic search (shepherd service in guix/home-configuration.scm)
          stdenv.cc.cc.lib # libstdc++.so.6 for Signet's ONNX native module
        ])
        ++ [
          # gc — Gas City CLI proxied to remote container on loving-kypris
          (pkgs.writeShellScriptBin "gc" (builtins.readFile ../scripts/gc-remote.sh))
        ];

      # openclaw's OpenAI device-code auth, driven over SSH against
      # loving-kypris. Lived in shared-devtools, whose header calls itself tooling
      # shared across hosts -- so ~150 lines naming one homelab box shipped to the
      # work Mac too, which never SSHes there. Sourced by the shared bash
      # integrations file via ~/.config/bash/extras.d. Refs: home-manager-0pr.10
      home.file.".config/bash/extras.d/openclaw.bash".text = ''
        # Generated by Home Manager. Sourced from home-manager-integrations.bash.
        # shellcheck shell=bash

                _openclaw_redact_secrets() {
                  sed -E 's/sk-[A-Za-z0-9_-]+/[REDACTED]/g'
                }

                openclaw-auth-loving-kypris() {
                  local host="loving-kypris"
                  local tmux_session="openclaw-openai-auth"
                  local log_path="/tmp/openclaw-openai-auth.log"
                  local auth_url="https://auth.openai.com/codex/device"
                  local code=""
                  local tries=0
                  local script_b64=""

                  # Compatibility shim: OpenClaw harness still looks up legacy
                  # openai-codex:default even after doctor migrates canonical profiles to
                  # openai:<email>. Copy alias from canonical OAuth profile; remove when
                  # upstream no longer requires the legacy profile id.
                  local -r _openclaw_codex_alias_js='const { DatabaseSync } = require("node:sqlite");
        const path = require("node:path");
        const os = require("node:os");
        const dbPath = path.join(os.homedir(), ".openclaw/agents/main/agent/openclaw-agent.sqlite");
        let db;
        try {
          db = new DatabaseSync(dbPath);
        } catch (err) {
          console.log("openclaw alias: cannot open auth store:", err.message);
          process.exit(0);
        }
        const row = db.prepare("SELECT * FROM auth_profile_store WHERE store_key = ?").get("primary");
        if (!row) {
          console.log("openclaw alias: no primary auth store row; skipping");
          process.exit(0);
        }
        const valueCol = ["store_json", "value", "data", "store_value"].find((col) => row[col] !== undefined);
        if (!valueCol) {
          console.log("openclaw alias: primary row has no JSON payload column; skipping");
          process.exit(0);
        }
        let store;
        try {
          store = JSON.parse(row[valueCol]);
        } catch (_err) {
          console.log("openclaw alias: invalid JSON in primary store; skipping");
          process.exit(0);
        }
        const profiles = store.profiles || {};
        if (profiles["openai-codex:default"] && profiles["openai-codex:default"].type === "oauth") {
          console.log("openclaw alias: openai-codex:default OAuth profile already present; skipping");
          process.exit(0);
        }
        const sourceId = Object.keys(profiles).find(
          (id) =>
            id.startsWith("openai:") &&
            id !== "openai-codex:default" &&
            profiles[id] &&
            profiles[id].type === "oauth",
        );
        if (!sourceId) {
          console.log("openclaw alias: no canonical openai:* OAuth profile; skipping");
          process.exit(0);
        }
        profiles["openai-codex:default"] = JSON.parse(JSON.stringify(profiles[sourceId]));
        store.profiles = profiles;
        const setParts = [valueCol + " = ?"];
        const params = [JSON.stringify(store)];
        if (row.updated_at !== undefined) {
          setParts.push("updated_at = ?");
          params.push(Date.now());
        }
        params.push("primary");
        db.prepare("UPDATE auth_profile_store SET " + setParts.join(", ") + " WHERE store_key = ?").run(...params);
        console.log("openclaw alias: copied OAuth profile " + sourceId + " -> openai-codex:default");'

                  _openclaw_auth_cleanup() {
                    ssh -q "$host" \
                      "tmux kill-session -t '$tmux_session' 2>/dev/null || true; rm -f '$log_path'"
                  }

                  _openclaw_ensure_codex_alias() {
                    script_b64=$(
                      printf '%s' "$_openclaw_codex_alias_js" | base64 -w0 2>/dev/null \
                        || printf '%s' "$_openclaw_codex_alias_js" | base64 | tr -d '\n'
                    )
                    ssh -q "$host" \
                      "podman exec openclaw-gateway sh -lc 'echo \"$script_b64\" | base64 -d > /tmp/openclaw-codex-alias.mjs && node /tmp/openclaw-codex-alias.mjs; rm -f /tmp/openclaw-codex-alias.mjs'"
                  }

                  trap '_openclaw_auth_cleanup' RETURN

                  if ! ssh -q "$host" \
                    "systemctl --user is-active --quiet openclaw-gateway || systemctl --user start openclaw-gateway"; then
                    echo "openclaw-auth-loving-kypris: failed to ensure openclaw-gateway is active on $host" >&2
                    return 1
                  fi

                  _openclaw_auth_cleanup

                  if ! ssh -q "$host" \
                    "tmux new-session -d -s '$tmux_session' \"podman exec -it openclaw-gateway sh -lc 'cd /app && node /app/openclaw.mjs models auth login --provider openai --device-code --force' 2>&1 | tee '$log_path'\""; then
                    echo "openclaw-auth-loving-kypris: failed to start remote auth session" >&2
                    return 1
                  fi

                  while [[ -z "$code" && $tries -lt 60 ]]; do
                    sleep 2
                    code=$(
                      ssh -q "$host" "grep -E 'Code:' '$log_path' 2>/dev/null | tail -1" \
                        | sed -n 's/.*Code:[[:space:]]*\([A-Z0-9-]*\).*/\1/p'
                    )
                    tries=$((tries + 1))
                  done

                  if [[ -z "$code" ]]; then
                    echo "openclaw-auth-loving-kypris: timed out waiting for device code in $log_path" >&2
                    ssh -q "$host" "cat '$log_path' 2>/dev/null" | _openclaw_redact_secrets >&2
                    return 1
                  fi

                  echo "OpenAI Codex device auth"
                  echo "URL:  $auth_url"
                  echo "Code: $code"
                  if command -v xdg-open >/dev/null 2>&1; then
                    xdg-open "$auth_url"
                  fi
                  read -r -p "Press Enter after completing auth in the browser..."

                  echo "Waiting for OAuth completion..."
                  sleep 5

                  echo "Ensuring legacy openai-codex:default alias..."
                  _openclaw_ensure_codex_alias

                  echo "Restarting openclaw-gateway..."
                  if ! ssh -q "$host" "systemctl --user restart openclaw-gateway"; then
                    echo "openclaw-auth-loving-kypris: failed to restart openclaw-gateway on $host" >&2
                    return 1
                  fi
                  sleep 3

                  echo "Verifying OpenAI auth..."
                  ssh -q "$host" \
                    "podman exec openclaw-gateway sh -lc 'cd /app && node /app/openclaw.mjs models auth list --provider openai'" \
                    | _openclaw_redact_secrets
                  ssh -q "$host" \
                    "podman exec openclaw-gateway sh -lc 'cd /app && node /app/openclaw.mjs models status --probe --probe-provider openai --probe-timeout 30000 --probe-concurrency 1'" \
                    | _openclaw_redact_secrets

                  echo "Recent gateway auth signals:"
                  ssh -q "$host" \
                    "journalctl --user -u openclaw-gateway -n 200 --no-pager" \
                    | grep -E 'openai-codex:default|insufficient_quota|subscription usage limit|auth profile|gpt-5.5|Codex app-server' \
                    | _openclaw_redact_secrets \
                    || true
                }
      '';

      xdg.configFile."autostart/synology-drive.desktop".text = ''
        [Desktop Entry]
        Name=Synology Drive Client
        Comment=Synology Drive Client
        Exec=synology-drive start
        Icon=synology-drive
        Terminal=false
        Type=Application
        Categories=Network;FileTransfer;
        X-GNOME-Autostart-enabled=true
      '';

      xdg.configFile."autostart/wl-clip-persist.desktop".text = ''
        [Desktop Entry]
        Name=wl-clip-persist
        Comment=Keep Wayland clipboard after programs close
        Exec=wl-clip-persist --clipboard both
        Terminal=false
        Type=Application
        Categories=Utility;
        X-GNOME-Autostart-enabled=true
      '';

      # GNOME doesn't ship StatusNotifierWatcher, so Qt tray apps (Telegram,
      # Synology Drive) appear to "not start" because their only UI is a tray
      # icon. The AppIndicator extension provides the watcher. It's installed
      # by guix-home into ~/.guix-home/profile/share/gnome-shell/extensions,
      # but `gnome-shell` only scans system extension dirs and
      # ~/.local/share/gnome-shell/extensions, so symlink it into the latter
      # on every activation. After this lands, log out + log back in, then:
      #   gnome-extensions enable appindicatorsupport@rgcjonas.gmail.com
      home.activation.linkAppIndicatorExtension = lib.hm.dag.entryAfter ["writeBoundary"] ''
        ext_id="appindicatorsupport@rgcjonas.gmail.com"
        src="$HOME/.guix-home/profile/share/gnome-shell/extensions/$ext_id"
        dst_dir="$HOME/.local/share/gnome-shell/extensions"
        if [ -e "$src" ]; then
          $DRY_RUN_CMD mkdir -p "$dst_dir"
          $DRY_RUN_CMD ln -sfn "$src" "$dst_dir/$ext_id"
        fi
      '';

      # The xdg.configFile "autostart/*.desktop" entries above are inert on
      # this host: XDG autostart processing is normally done by a systemd
      # --user xdg-desktop-autostart generator (or a full desktop session
      # manager like gnome-session), and this session runs neither -- it's
      # GNU Shepherd + elogind under Hyprland/omarchy, confirmed by
      # `systemctl --user` failing with "Failed to connect to user scope
      # bus". Omarchy's own autostart mechanism is the hardcoded
      # `hl.exec_cmd` list Hyprland runs from ~/.config/hypr/autostart.lua
      # on the "hyprland.start" event; nothing else reads ~/.config/autostart.
      # That file is omarchy's mutable per-user config (copied out on first
      # run, not a home-manager symlink), so wire both apps into it the same
      # way omarchy-install-service-sunshine does, inside a marker-delimited
      # block so re-running this activation regenerates the block instead of
      # accumulating duplicate/blank lines, and dropping an entry from the
      # list below actually removes its line. Guarded on the file already
      # existing, so hosts without omarchy/Hyprland (e.g. the GNOME/darwin
      # machines this aspect is also shared with) are left untouched and
      # fall back to the XDG autostart entries above.
      home.activation.autostartHyprland = let
        # synology-drive: `autostart` (not `start`) sleeps 10s before
        # launching -- the vendor script's own accommodation for exactly
        # this race: at session start the app's only UI is a tray icon
        # registered via org.kde.StatusNotifierItem, and racing
        # Quickshell's StatusNotifierWatcher registration loses the icon
        # with no other sign the app is running. The XDG autostart
        # .desktop entry above keeps `start` since it targets session
        # managers with their own startup ordering.
        commands = [
          "synology-drive autostart"
          "wl-clip-persist --clipboard both"
        ];
        launchLines =
          lib.concatMapStringsSep "\n        " (cmd: "echo 'o.launch_on_start(\"${cmd}\")'") commands;
      in
        lib.hm.dag.entryAfter ["writeBoundary"] ''
          autostart_file="$HOME/.config/hypr/autostart.lua"
          begin_marker="-- BEGIN home-manager autostart"
          end_marker="-- END home-manager autostart"
          if [[ -v DRY_RUN ]]; then
            echo "Would ensure home-manager-managed autostart block in $autostart_file"
          elif [ -f "$autostart_file" ]; then
            tmp="$(mktemp)"
            ${pkgs.gawk}/bin/awk -v begin="$begin_marker" -v end="$end_marker" '
              # One-time migration: earlier revisions appended these two
              # bare, unmarked lines directly instead of a managed block.
              $0 == "o.launch_on_start(\"synology-drive start\")" { next }
              $0 == "o.launch_on_start(\"synology-drive autostart\")" { next }
              $0 == begin { skip = 1; next }
              $0 == end   { skip = 0; next }
              skip { next }
              { a[++n] = $0 }
              END { while (n > 0 && a[n] == "") n--; for (i = 1; i <= n; i++) print a[i] }
            ' "$autostart_file" > "$tmp"
            {
              echo ""
              echo "$begin_marker"
              ${launchLines}
              echo "$end_marker"
            } >> "$tmp"
            mv "$tmp" "$autostart_file"
          fi
        '';

      programs.gh = {
        enable = true;
        gitCredentialHelper.enable = true;
        settings = {
          git_protocol = "https";
          prompt = "enabled";
          aliases = {
            co = "pr checkout";
          };
        };
      };

      programs.topgrade = {
        enable = true;
        settings = {
          # Deliberately excludes the kernel. `just upgrade-kernel` used to run
          # here, bumping to whatever CachyOS tagged that day, and the deploy
          # then built it inline for ~3h -- unattended, unreviewed. Worse, the
          # post_commands `guix gc` deleted the result before any reconfigure
          # adopted it, so 12 days of runs landed zero system generations while
          # rebuilding the kernel repeatedly. Kernel upgrades are now explicit:
          #   just upgrade-kernel && just deploy-mahakala-system-full
          #
          # Separate steps rather than one `just deploy-mahakala`, for the same
          # reason as the darwin config: `deploy-mahakala` is a flat recipe, so a
          # persistent Guix forge outage aborted every later line -- including the
          # Home Manager switch, whose closure is already locked and would have
          # succeeded. Split, each failure is contained to its own step. Ordering
          # is preserved by the numeric prefixes (topgrade sorts keys).
          pre_commands = {
            "1. Deploy Guix System" = "cd ~/.config/home-manager && just guix-pull-system && just deploy-mahakala-system";
            "2. Deploy Guix Home" = "cd ~/.config/home-manager && just guix-pull-home && just deploy-mahakala-guix-only";
            "3. Flake inputs" = "cd ~/.config/home-manager && just update";
            "4. Deploy Home Manager" = "cd ~/.config/home-manager && just deploy-mahakala-hm-only";
          };
          misc = {
            assume_yes = true;
            # Retry transient failures instead of aborting the run. `guix pull`
            # fetches four channels from codeberg/sourcehut mirrors, and a single
            # forge hiccup (observed: "Git error: unexpected http status code:
            # 504" from the nonguix mirror) otherwise kills the whole deploy --
            # including the Home Manager switch that had nothing to do with it.
            # ask_retry must be off too, or an unattended run blocks on a prompt.
            auto_retry = 2;
            ask_retry = false;
            pre_sudo = true;
            show_distribution_summary = false;
            disable = ["nix" "home_manager" "containers" "helm" "guix" "bun" "node" "emacs" "claude_code" "pi" "system" "distrobox" "a_m"];
          };
          commands = {
            "Distrobox (arch)" = "distrobox-upgrade arch";
            "Homebrew (arch distrobox)" = "LC_ALL=C LANG=C distrobox enter arch -- bash --login -c 'export HOMEBREW_NO_ASK=1; brew update && brew upgrade'";
          };
          post_commands = {
            "Garbage collect Nix" = "nix-collect-garbage -d";
            # Retain 2w of system generations, not 1d: a same-day kernel needs a
            # rollback target that outlives the day it was deployed. The kernel
            # itself is pinned by the kernel-gc-root GC root in the Justfile.
            "Garbage collect Guix" = "guix package --delete-generations 2w && guix home delete-generations 2w && (sudo guix system delete-generations 2w 2> >(grep -v 'no matching generation' >&2) || true) && sudo guix gc";
            "Remove unused Flatpak runtimes" = "flatpak uninstall --unused -y";
            "Prune Podman images" = "podman image prune -a -f";
            "Empty Trash" = "chmod -R u+w ~/.local/share/Trash/files ~/.local/share/Trash/info 2>/dev/null || true; rm -rf ~/.local/share/Trash/files/* ~/.local/share/Trash/info/*";
          };
        };
      };
    };
  };
}
