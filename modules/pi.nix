{inputs, ...}: {
  # pi's user-level MCP servers and npm packages, declared per host.
  #
  # Both files stay writable, because pi writes to them: `/mcp` saves exposure
  # and enabled-state changes to ~/.pi/agent/mcp.json, and `pi install` writes
  # ~/.pi/agent/settings.json. So neither is a store symlink. Activation merges
  # the declared entries in and leaves every other entry alone:
  #   - mcpServers: a declared server replaces the entry of the same name, so
  #     a `/mcp` change to a declared server lasts until the next switch. Other
  #     servers are untouched, except removedMcpServers, which are deleted by
  #     name.
  #   - packages: a declared spec is `npm:name`, which tracks the latest
  #     release, or `npm:name@version`, which is pinned. A listed entry with
  #     the same name in another form is removed and the declared one
  #     installed through pi itself. Each switch runs `pi update` for an
  #     unpinned spec, so it moves to the latest release; pi does not update
  #     packages on its own. removedPackages are removed by name.
  #   - skills: each declared resource filter is added to settings.json's
  #     `skills` array when it is missing. Other entries, such as `pi config`
  #     toggles, stay. Activation never deletes an entry.
  #   - settings: other declared settings.json keys are merged in
  #     recursively at each switch. A declared value wins; keys that are not
  #     declared stay as they are.
  # A failed install (no network) warns and leaves the rest of activation to
  # run; the next switch retries.
  #
  # Since pi 0.99 MCP is built in, so pi-mcp-adapter is no longer needed. An
  # installed adapter also replaces the built-in support for the whole session
  # (it registers /mcp), so every host removes it.
  den.aspects.piAgent.homeManager = {
    pkgs,
    lib,
    config,
    ...
  }: let
    cfg = config.piAgent;
    jq = lib.getExe pkgs.jq;
    # Activation PATH is bash, coreutils, diffutils, findutils, gettext, grep,
    # sed, jq and ncurses only; anything else is named by store path.
    awk = "${pkgs.gawk}/bin/awk";
    pi = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
    agentDir = "${config.home.homeDirectory}/.pi/agent";
    declaredMcp = pkgs.writeText "pi-mcp-servers.json" (builtins.toJSON {mcpServers = cfg.mcpServers;});

    # The compression chain: which optional token-saving layers pi loads.
    # chain.json records the user's choice. Activation seeds it once and
    # applies it; `pi-chain` flips one layer at runtime. Both use chainShell,
    # so the two can never diverge. Activation never rewrites an existing
    # chain.json, which is what makes a runtime toggle survive a switch.
    chainState = "${agentDir}/chain.json";
    chainDefaults = {
      rtk = true;
      billion-context = true;
      context-mode = false;
      caveman = false;
      headroom = false;
    };
    chainShell = ''
      # --- pi compression chain (piChain activation and pi-chain share this) ---
      chain=${lib.escapeShellArg chainState}
      settings=${lib.escapeShellArg "${agentDir}/settings.json"}
      chain_defaults=${lib.escapeShellArg (builtins.toJSON chainDefaults)}
      console_extension=${lib.escapeShellArg "${config.home.homeDirectory}/.local/share/opencode-console/cli/pi-extension.js"}
      ext_dir=${lib.escapeShellArg "${agentDir}/extensions"}
      ext_off_dir=${lib.escapeShellArg "${agentDir}/extensions-off"}
      rtk_extension=${lib.escapeShellArg "${agentDir}/extensions/rtk.ts"}
      caveman_extension=${lib.escapeShellArg "${agentDir}/extensions/caveman-native.js"}

      pi_chain_warn() {
        printf 'pi-chain: %s\n' "$*" >&2
      }

      # pi auto-discovers every extension file in ext_dir, so presence there is
      # what turns a discovered extension on; a settings entry only adds one.
      # Toggling therefore moves the file between ext_dir and ext_off_dir,
      # which keeps it, so enabling again restores it instead of reinstalling.
      pi_chain_ext() {
        local path="$1" want="$2" parked
        parked="$ext_off_dir/$(basename -- "$path")"
        if [ "$want" = true ]; then
          [ -e "$path" ] && return 0
          if [ ! -e "$parked" ]; then
            pi_chain_warn "$path is not installed; install that layer once (rtk install / caveman enable pi), then enable it"
            return 0
          fi
          if [ -n "''${DRY_RUN:-}" ]; then
            echo "would move $parked back to $path"
            return 0
          fi
          mkdir -p -- "$ext_dir"
          mv -- "$parked" "$path" || pi_chain_warn "could not restore $path"
          return 0
        fi
        [ -e "$path" ] || return 0
        if [ -n "''${DRY_RUN:-}" ]; then
          echo "would move $path to $ext_off_dir"
          return 0
        fi
        mkdir -p -- "$ext_off_dir"
        mv -- "$path" "$parked" || pi_chain_warn "could not move $path out of $ext_dir"
      }

      # Apply the extension layers by file placement.
      pi_chain_extensions() {
        local chain_json
        chain_json="$(pi_chain_json)"
        pi_chain_ext "$rtk_extension" "$(printf '%s' "$chain_json" | ${jq} -r '.rtk // false')"
        pi_chain_ext "$caveman_extension" "$(printf '%s' "$chain_json" | ${jq} -r '.caveman // false')"
      }

      # The chain as JSON: the state file when it exists, else the seed.
      pi_chain_json() {
        if [ -e "$chain" ]; then
          cat -- "$chain"
        else
          printf '%s\n' "$chain_defaults"
        fi
      }

      # Write the seed once. An existing chain.json is the user's and stays.
      pi_chain_seed() {
        if [ -e "$chain" ]; then
          return 0
        fi
        if [ -n "''${DRY_RUN:-}" ]; then
          echo "would write $chain"
          return 0
        fi
        mkdir -p -- "$(dirname -- "$chain")"
        if (umask 077 && printf '%s\n' "$chain_defaults" >"$chain.hm-tmp") && mv -- "$chain.hm-tmp" "$chain"; then
          return 0
        fi
        pi_chain_warn "could not write $chain"
        return 1
      }

      # Rewrite only packages, extensions and defaultProvider in settings.json
      # from the chain; every other key is left as it is.
      pi_chain_apply() {
        local chain_json current merged summary
        chain_json="$(pi_chain_json)"
        if ! printf '%s' "$chain_json" | ${jq} -e 'type == "object"' >/dev/null 2>&1; then
          pi_chain_warn "$chain is not a JSON object; left $settings unchanged"
          return 1
        fi
        current='{}'
        if [ -e "$settings" ]; then
          current="$(cat -- "$settings")"
        fi
        if ! merged="$(printf '%s' "$current" | ${jq} --argjson c "$chain_json" \
            --arg console "$console_extension" \
            --arg rtk "$rtk_extension" \
            --arg caveman "$caveman_extension" '
              . + {
                packages: [
                  (if ($c["billion-context"] // false) then "npm:billion-context" else empty end),
                  (if ($c["context-mode"] // false) then "npm:context-mode" else empty end)
                ],
                # rtk and caveman are switched by file placement, so drop any
                # entry an older chain wrote for them instead of adding one.
                extensions: ((
                  [(.extensions[]?) | select(. != $console and . != $rtk and . != $caveman)]
                  + [$console]
                ) | unique),
                # A provider and a model are one choice: OpenCode Go does not
                # serve claude-sonnet-5-5, so the model has to move with the
                # provider or the default pair fails on the first request.
                defaultProvider: (if ($c["headroom"] // false) then "lego-claude" else "opencode-go" end),
                defaultModel: (if ($c["headroom"] // false) then "claude-sonnet-5-5" else "deepseek-v4.1-flash" end)
              }')"; then
          pi_chain_warn "$settings is not valid JSON; left it unchanged"
          return 1
        fi
        if [ -e "$settings" ] && [ "$merged" = "$(${jq} . "$settings")" ]; then
          return 0
        fi
        if [ -n "''${DRY_RUN:-}" ]; then
          echo "would write $settings"
          return 0
        fi
        mkdir -p -- "$(dirname -- "$settings")"
        if ! { (umask 077 && printf '%s\n' "$merged" >"$settings.hm-tmp") && mv -- "$settings.hm-tmp" "$settings"; }; then
          pi_chain_warn "could not write $settings"
          return 1
        fi
        summary="$(printf '%s' "$merged" | ${jq} -r '"packages=" + (if (.packages | length) == 0 then "none" else (.packages | join(",")) end) + " provider=" + .defaultProvider')"
        echo "pi-chain: updated $settings ($summary)"
      }

      # settings.json first, then the extension files: a failure part way
      # leaves the recorded choice readable instead of half applied.
      pi_chain_apply_all() {
        pi_chain_apply
        pi_chain_extensions
      }
    '';
    chainCli = pkgs.writeShellScriptBin "pi-chain" ''
      # pi-chain — turn the optional layers of pi's compression chain on or off.
      #
      # ${chainState} is the single source of truth: `enable` and `disable`
      # change one boolean there, then apply the chain to
      # ${agentDir}/settings.json, on exactly the code path that the Home
      # Manager `piChain` activation uses. A switch seeds that file when it is
      # absent and never overwrites it, so a runtime toggle survives the next
      # switch.
      #
      # A layer that adds a package (billion-context, context-mode) only
      # changes settings.json: install the npm package with
      # `pi install npm:<name>` if pi reports it missing.
      #
      # rtk and caveman are extensions, and pi auto-discovers every file in
      # ${agentDir}/extensions. Presence there is the switch, so this script
      # moves the file between extensions/ and extensions-off/ rather than
      # writing a settings entry; `pi install`-style entries are additive and
      # can never switch a discovered extension off.
      set -euo pipefail

      ${chainShell}

      layers="rtk billion-context context-mode caveman headroom"

      layer_description() {
        case "$1" in
          rtk) echo "extension: rewrite bash calls through rtk to cut tool-output tokens" ;;
          billion-context) echo "package: billion-context compression between turns" ;;
          context-mode) echo "package: context-mode context tooling" ;;
          caveman) echo "extension: caveman prompt and reply compression proxy" ;;
          headroom) echo "provider: route requests through lego-claude (Headroom)" ;;
          *) return 1 ;;
        esac
      }

      layer_contribution() {
        case "$1" in
          rtk) echo "$rtk_extension" ;;
          billion-context) echo "npm:billion-context" ;;
          context-mode) echo "npm:context-mode" ;;
          caveman) echo "$caveman_extension" ;;
          headroom) echo "lego-claude (instead of opencode-go)" ;;
        esac
      }

      usage() {
        cat <<'EOF'
      usage: pi-chain <command>

        status           each layer, its state, and the result applied to settings.json
        list             the layer names with one-line descriptions
        enable <name>    turn one layer on and apply it now
        disable <name>   turn one layer off and apply it now
      EOF
      }

      case "''${1:-status}" in
        list)
          for name in $layers; do
            printf '%-16s %s\n' "$name" "$(layer_description "$name")"
          done
          ;;
        status)
          chain_json="$(pi_chain_json)"
          printf '%-16s %-4s %s\n' layer state contributes
          for name in $layers; do
            if printf '%s' "$chain_json" | ${jq} -e --arg k "$name" '.[$k] // false' >/dev/null; then
              printf '%-16s %-4s %s\n' "$name" on "$(layer_contribution "$name")"
            else
              printf '%-16s %-4s %s\n' "$name" off -
            fi
          done
          printf '\n'
          # For an extension layer the file is the truth, so say when the
          # recorded choice and the installed file disagree (a `caveman enable
          # pi` or `pi install` can put one back behind this script's back).
          for name in rtk caveman; do
            case "$name" in
              rtk) path="$rtk_extension" ;;
              caveman) path="$caveman_extension" ;;
            esac
            if printf '%s' "$chain_json" | ${jq} -e --arg k "$name" '.[$k] // false' >/dev/null; then
              [ -e "$path" ] || echo "note: $name is on but $path is missing; install it once, then run pi-chain enable $name"
            else
              [ ! -e "$path" ] || echo "note: $name is off but $path is still loaded; run pi-chain disable $name to apply it"
            fi
          done
          printf '\n'
          if [ -e "$settings" ]; then
            ${jq} -r '"packages:        " + ((.packages // []) | if length == 0 then "none" else join(", ") end), "extensions:      " + ((.extensions // []) | if length == 0 then "none" else join(", ") end), "defaultProvider: " + (.defaultProvider // "unset"), "defaultModel:    " + (.defaultModel // "unset")' "$settings"
          else
            echo "settings: $settings does not exist yet"
          fi
          ;;
        enable|disable)
          name="''${2:-}"
          if ! layer_description "$name" >/dev/null 2>&1; then
            printf 'pi-chain: unknown layer: %s\nvalid layers: %s\n' "''${name:-<none given>}" "$layers" >&2
            exit 2
          fi
          pi_chain_seed
          if [ "$1" = enable ]; then value=true; else value=false; fi
          updated="$(pi_chain_json | ${jq} --arg k "$name" --argjson v "$value" '.[$k] = $v')"
          if [ -n "''${DRY_RUN:-}" ]; then
            echo "would write $chain"
          else
            (umask 077 && printf '%s\n' "$updated" >"$chain.hm-tmp") && mv -- "$chain.hm-tmp" "$chain"
          fi
          pi_chain_apply_all
          ;;
        help|-h|--help)
          usage
          ;;
        *)
          printf 'pi-chain: unknown command: %s\n' "$1" >&2
          usage >&2
          exit 2
          ;;
      esac
    '';
  in {
    options.piAgent = {
      mcpServers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
        default = {};
        description = ''
          Entries for `mcpServers` in ~/.pi/agent/mcp.json, in pi's format
          (docs/mcp.md). Never put a credential here: use `''${VAR}` or a
          `!command` value, which pi resolves when it connects.
        '';
      };
      removedMcpServers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Server names to delete from `mcpServers` in ~/.pi/agent/mcp.json at each switch.";
      };
      packages = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "npm:.+");
        default = [];
        description = ''
          pi packages, as `npm:name` (tracks the latest release: each switch
          runs `pi update` for it) or `npm:name@version` (pinned).
        '';
      };
      removedPackages = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "pi packages to remove, by source without a version (`npm:name`).";
      };
      settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
        example = {contextMode.excludeTools = ["caveman_retrieve"];};
        description = ''
          Other keys for ~/.pi/agent/settings.json, merged in recursively at
          each switch (jq `*`): a declared value replaces the one in the
          file, and undeclared keys stay. Use `packages` and `skills` for
          those two keys. Never put a credential here.
        '';
      };
      skills = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["-/Users/me/.agents/skills/research"];
        description = ''
          Entries for `skills` in ~/.pi/agent/settings.json, in pi's resource
          filter syntax (docs/settings.md, Resources): a path, `!glob`,
          `+path` or `-path`. A `-path` entry stops pi from loading one
          discovered skill, such as a user skill whose name collides with a
          package skill.
        '';
      };
    };

    config.home.packages = [chainCli];

    config.home.activation = {
      piMcpServers = lib.hm.dag.entryAfter ["writeBoundary"] ''
        mcp=${lib.escapeShellArg "${agentDir}/mcp.json"}
        current='{}'
        [ -e "$mcp" ] && current="$(cat "$mcp")"
        if merged="$(printf '%s' "$current" | ${jq} --slurpfile d ${declaredMcp} \
            --argjson removed ${lib.escapeShellArg (builtins.toJSON cfg.removedMcpServers)} \
            '.mcpServers = ((.mcpServers // {}) + $d[0].mcpServers | with_entries(select(.key as $k | $removed | index($k) | not)))')"; then
          if [ ! -e "$mcp" ] || [ "$merged" != "$(${jq} . "$mcp")" ]; then
            # BSD install cannot read a pipe, so write beside the target and
            # rename, which also keeps a reader from seeing half a file.
            run mkdir -p ${lib.escapeShellArg agentDir}
            if [ -z "''${DRY_RUN:-}" ]; then
              (umask 077 && printf '%s\n' "$merged" >"$mcp.hm-tmp") && mv "$mcp.hm-tmp" "$mcp"
            else
              echo "would write $mcp"
            fi
          fi
        else
          warnEcho "pi: $mcp is not valid JSON; left it unchanged"
        fi
      '';

      piPackages = lib.hm.dag.entryAfter ["writeBoundary" "piMcpServers"] ''
        settings=${lib.escapeShellArg "${agentDir}/settings.json"}
        # pi installs npm packages with npm, and git ones with git.
        export PATH=${lib.makeBinPath [pi pkgs.nodejs pkgs.git]}:$PATH
        piListed() {
          [ -e "$settings" ] || return 0
          ${jq} -r '.packages[]? | if type == "object" then .source else . end' "$settings" 2>/dev/null |
            ${awk} -v n="$1" '$0 == n || index($0, n "@") == 1' | head -n 1
        }
        for spec in ${lib.escapeShellArgs cfg.packages}; do
          # A trailing @version pins the spec. A scope's @ comes before a /,
          # so npm:@scope/name stays unpinned.
          name=$spec
          if [[ $spec =~ ^(npm:.+)@[^@/]+$ ]]; then
            name=''${BASH_REMATCH[1]}
          fi
          have="$(piListed "$name")"
          if [ "$have" = "$spec" ]; then
            if [ "$name" = "$spec" ]; then
              run pi update "$spec" || warnEcho "pi: could not update $spec; the next switch retries"
            fi
            continue
          fi
          if [ -n "$have" ]; then
            run pi remove "$have" || warnEcho "pi: could not remove $have"
          fi
          run pi install "$spec" || warnEcho "pi: could not install $spec; the next switch retries"
        done
        for name in ${lib.escapeShellArgs cfg.removedPackages}; do
          have="$(piListed "$name")"
          if [ -n "$have" ]; then
            run pi remove "$have" || warnEcho "pi: could not remove $have"
          fi
        done
      '';

      # After piPackages: `pi install` rewrites `packages` in settings.json,
      # and the chain owns that key. chain.json is seeded only when absent.
      piChain = lib.hm.dag.entryAfter ["writeBoundary" "piPackages"] ''
        ${chainShell}
        pi_chain_seed
        pi_chain_apply_all
      '';

      # After piPackages, because `pi install` and `pi remove` rewrite
      # settings.json.
      piSettings = lib.mkIf (cfg.settings != {}) (lib.hm.dag.entryAfter ["writeBoundary" "piPackages"] ''
        settings=${lib.escapeShellArg "${agentDir}/settings.json"}
        current='{}'
        [ -e "$settings" ] && current="$(cat "$settings")"
        if merged="$(printf '%s' "$current" | ${jq} --argjson d ${lib.escapeShellArg (builtins.toJSON cfg.settings)} '. * $d')"; then
          if [ ! -e "$settings" ] || [ "$merged" != "$(${jq} . "$settings")" ]; then
            run mkdir -p ${lib.escapeShellArg agentDir}
            if [ -z "''${DRY_RUN:-}" ]; then
              (umask 077 && printf '%s\n' "$merged" >"$settings.hm-tmp") && mv "$settings.hm-tmp" "$settings"
            else
              echo "would write $settings"
            fi
          fi
        else
          warnEcho "pi: $settings is not valid JSON; left it unchanged"
        fi
      '');

      # After piPackages, because `pi install` and `pi remove` rewrite
      # settings.json. The declared entries go after the existing ones, in
      # declared order.
      piSkills = lib.mkIf (cfg.skills != []) (lib.hm.dag.entryAfter ["writeBoundary" "piPackages" "piSettings"] ''
        settings=${lib.escapeShellArg "${agentDir}/settings.json"}
        current='{}'
        [ -e "$settings" ] && current="$(cat "$settings")"
        if merged="$(printf '%s' "$current" | ${jq} --argjson d ${lib.escapeShellArg (builtins.toJSON cfg.skills)} \
            '.skills = ((.skills // []) as $s | $s + ($d - $s))')"; then
          if [ ! -e "$settings" ] || [ "$merged" != "$(${jq} . "$settings")" ]; then
            run mkdir -p ${lib.escapeShellArg agentDir}
            if [ -z "''${DRY_RUN:-}" ]; then
              (umask 077 && printf '%s\n' "$merged" >"$settings.hm-tmp") && mv "$settings.hm-tmp" "$settings"
            else
              echo "would write $settings"
            fi
          fi
        else
          warnEcho "pi: $settings is not valid JSON; left it unchanged"
        fi
      '');
    };
  };
}
