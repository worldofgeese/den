{
  den,
  inputs,
  ...
}: {
  # Shared developer tooling aspect — packages and programs used on both
  # mahakala (Linux workstation) and M-02877 (macOS work machine).
  # Host-specific additions go in workstation.nix or dktaohan.nix.
  den.aspects.sharedDevtools = {
    includes = [den.aspects.devtools];
    homeManager = {
      pkgs,
      lib,
      ...
    }: let
      agents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
    in {
      home.packages = with pkgs;
        [
          nodejs
          bun
          kubectl
          shellcheck
          yq-go
          glab
          just
          bash-preexec
          agents.omp
          agents.claude-code
          agents.claude-agent-acp
          agents.copilot-cli
          # Secret lookups for both hosts, declared in secretspec.toml. Shared so
          # mahakala and M-02877 resolve gateway/API credentials the same way
          # rather than mahakala falling back to gopass for the same secret.
          secretspec
          # Pushes to the worldofgeese binary cache via `just cachix-push`.
          cachix
          herdr
          bv
          # ACP agents query current NixOS, Home Manager, and nix-darwin data.
          mcp-nixos
          mcp-agent-mail
          # Governance kernel, used on every host. Was Darwin-excluded and
          # installed there by `cargo install decapod` in an activation hook,
          # which failed silently and left the version unpinned.
          decapod
        ]
        ++ lib.optionals (!pkgs.stdenv.hostPlatform.isDarwin) [
          rtk
          br
        ];

      # uv, plus the tools it manages. Declarative replacement for
      # `uv tool install`: entries are installed and upgraded on activation.
      #
      # crucible-llm is not on PyPI in a usable state (PyPI 0.1.0 is stale), so
      # it is installed from git. The `name @ git+url` form is required rather
      # than a bare `git+...` URL for two reasons: `uv tool upgrade` rejects a
      # bare URL ("URL requirement must be preceded by a package name"), and
      # `tool.prune` derives the keep-list by regex from the leading name, which
      # for a bare URL yields "git" and would uninstall the tool on every
      # activation.
      programs.uv = {
        enable = true;

        # uv's own CPython builds come from python-build-standalone, which are
        # FHS binaries requesting /lib64/ld-linux-x86-64.so.2. Guix System has
        # no /lib64, so they cannot execute at all:
        #   $ ~/.local/share/uv/python/cpython-3.14.6-*/bin/python3.14 --version
        #   cannot execute: required file not found
        # uv reports that as "Python interpreter not found", which is misleading
        # since the file is present; the missing piece is the loader. When uv had
        # pinned a tool to one of those, `uv tool upgrade` failed and took the
        # whole activation with it.
        #
        # only-system keeps uv off those downloads, but it does not by itself
        # give uv something to run: activation uses a fixed PATH of Nix store
        # paths, so neither ~/.guix-home/profile/bin nor home.packages is
        # visible and uv fails with "No interpreter found in search path".
        # home.extraActivationPath below puts python3 on that PATH; uv resolves
        # an interpreter by searching PATH, so UV_PYTHON with an absolute path
        # does not work here (uv treats it as a version request and resolves it
        # back to the unusable managed install).
        settings.python-preference = "only-system";

        tool = {
          packages = [
            "crucible-llm @ git+https://github.com/jkitchin/crucible"
          ];
          prune = true;
        };
      };

      # uv resolves its interpreter from PATH during activation, and activation
      # does not inherit the login PATH. See programs.uv above. git is needed for
      # the same reason: uv shells out to it for `git+` tool requirements and
      # otherwise fails with "Git executable not found".
      #
      # python313, not python3: crucible-llm depends on libsql, whose newest
      # release (0.1.11) ships macOS arm64 wheels only up to cp313. On 3.14 uv
      # falls back to building it from source, which needs a Rust toolchain and a
      # linker that the store-only activation PATH does not have. Bump this when
      # libsql publishes a cp314 wheel.
      home.extraActivationPath = [pkgs.python313 pkgs.git];

      # `uv tool install` warns "`~/.local/bin` is not on your PATH" on every
      # activation. The directory is on the *login* PATH via home.sessionPath;
      # it is only missing from the store-only activation PATH described above,
      # so the warning is noise. Prepending it here silences it. Activation
      # entries share one bash process, so this export also reaches later
      # entries -- harmless, since the login shell has the same directory.
      home.activation.uvToolBinOnPath = lib.hm.dag.entryBefore ["uvTool"] ''
        export PATH="$HOME/.local/bin:$PATH"
      '';

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
          auto_sync = lib.mkDefault true;
          sync_frequency = "5m";
          search_mode = "fuzzy";
        };
      };

      # Guix Home owns ~/.bashrc on mahakala, so Home Manager cannot inject
      # Bash init snippets directly. Export one sourceable fragment instead.
      # bash-preexec must load before Atuin/Starship; zoxide stays last.
      home.file.".config/bash/home-manager-integrations.bash".text = ''
                # Generated by Home Manager. Sourced from Guix Home's ~/.bashrc.
                # shellcheck shell=bash
                [[ $- == *i* ]] || return

                if command -v direnv >/dev/null 2>&1; then
                  eval "$(direnv hook bash)"
                fi

                _hm_bash_preexec="${pkgs.bash-preexec}/share/bash/bash-preexec.sh"
                # shellcheck source=/dev/null
                [[ -r "$_hm_bash_preexec" ]] && source "$_hm_bash_preexec"
                unset _hm_bash_preexec

                if command -v atuin >/dev/null 2>&1; then
                  eval "$(atuin init bash)"
                fi

                if command -v starship >/dev/null 2>&1; then
                  eval "$(starship init bash)"
                fi

                if command -v fzf >/dev/null 2>&1; then
                  eval "$(fzf --bash)"
                fi

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

                if command -v zoxide >/dev/null 2>&1; then
                  eval "$(zoxide init bash)"
                fi
      '';
    };
  };
}
