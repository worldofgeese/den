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
