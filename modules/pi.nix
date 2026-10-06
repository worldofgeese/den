{inputs, ...}: {
  # pi's user-level MCP servers and npm packages, declared per host.
  #
  # Both files stay writable, because pi writes to them: `/mcp` saves exposure
  # and enabled-state changes to ~/.pi/agent/mcp.json, and `pi install` writes
  # ~/.pi/agent/settings.json. So neither is a store symlink. Activation merges
  # the declared entries in and leaves every other entry alone:
  #   - mcpServers: a declared server replaces the entry of the same name, so
  #     a `/mcp` change to a declared server lasts until the next switch. Other
  #     servers are untouched.
  #   - packages: each declared spec is pinned (`npm:name@version`). A listed
  #     entry with the same name at another version is removed and the pinned
  #     one installed through pi itself. removedPackages are removed by name.
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
      packages = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "npm:.+@[^@/]+");
        default = [];
        description = "Pinned pi packages, as `npm:name@version`.";
      };
      removedPackages = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "pi packages to remove, by source without a version (`npm:name`).";
      };
    };

    config.home.activation = {
      piMcpServers = lib.hm.dag.entryAfter ["writeBoundary"] ''
        mcp=${lib.escapeShellArg "${agentDir}/mcp.json"}
        current='{}'
        [ -e "$mcp" ] && current="$(cat "$mcp")"
        if merged="$(printf '%s' "$current" | ${jq} --slurpfile d ${declaredMcp} \
            '.mcpServers = ((.mcpServers // {}) + $d[0].mcpServers)')"; then
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
          have="$(piListed "''${spec%@*}")"
          [ "$have" = "$spec" ] && continue
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
    };
  };
}
