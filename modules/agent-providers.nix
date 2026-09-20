#
# Provider wiring for the CLI coding agents.
#
# modules/shared-devtools.nix installs omp, pi, claude-code and Caveman Code;
# until now each was expected to find the model gateway on its own, and only
# the one Emacs spawns (modules/doom.d/.../agent-shell/config.el) actually did.
# The rest either sat on a vendor default or, in Caveman Code's case, carried a
# hand-pasted `vk_...` key in an untracked file (home-manager-l23).
#
# Shapes come from the gateway's own setup docs, which are the authoritative
# statement of what it requires and are not published as prose anywhere in this
# repo's reach: LEGO/ai-model-gateway-client, src/features/docs/pages/{PiPage,
# ClaudeCodePage,OpencodePage}.tsx. Addresses, ids and the key command come
# from gateway.json via modules/gateway.nix, so this file holds adapters only.
#
# Those docs hand you a credential to paste or export, which suits a human
# setting up one laptop. This is a store-rendered config, so the one place this
# file departs from them is the credential: it is never a value here. Every
# harness takes a *command* that prints it at agent-process start, so it reaches
# neither the Nix store nor the work tree (ADR 0001). omp, pi and Caveman Code
# read a `!command` apiKey themselves; Claude Code has no such marker, so its
# wrapper runs the lookup and exports the result.
#
# Refs: home-manager-l23, home-manager-8vh, home-manager-0pr.2
{
  den,
  gateway,
  inputs,
  ...
}: {
  den.aspects.agentProviders.homeManager = {
    config,
    lib,
    pkgs,
    ...
  }: let
    agents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};

    # headroom rewrites prior turns and forwards upstream, so pointing the
    # harnesses at its loopback port is what makes a prefix cache hit across
    # them. Same address agent-shell already uses; entity-keyed because 8787 is
    # the host port on mahakala but container-internal on M-02877.
    baseUrl = gateway.headroom.loopbackUrl (
      if pkgs.stdenv.hostPlatform.isDarwin
      then "M-02877"
      else "mahakala"
    );

    keyCommand = gateway.keyCommand config.home.homeDirectory;

    inherit (gateway) models modelIds;

    # The gateway rejects the per-tool `eager_input_streaming` field that these
    # harnesses send by default, surfacing as "Extra inputs are not permitted".
    # The vendor docs require this on every Claude provider. Not reproducible
    # against the live gateway on 2026-09-19 (all three endpoints accepted the
    # field), so this is carried on the documented requirement rather than on a
    # failure seen here -- it costs nothing if the gateway has since relaxed.
    compat.supportsEagerToolInputStreaming = false;

    # One provider block, spelled the way each fork's schema wants it.
    #
    # pi and Caveman Code share a models.json schema. omp renamed the file to
    # models.yml and validates it strictly: an unknown key disables *all*
    # custom providers with a warning, so pi's `forceAdaptiveThinking` and
    # `thinkingLevelMap` must not appear there. omp's equivalent is a
    # `thinking.mode` of "anthropic-adaptive" (verified against its embedded
    # ModelThinkingSchema / ApiCompatSchema).
    piModel = slot: let
      model = models.${slot};
    in
      model
      // {inherit compat;}
      // lib.optionalAttrs model.reasoning {
        thinkingLevelMap = {
          xhigh = "xhigh";
          max = "max";
        };
        compat = compat // {forceAdaptiveThinking = true;};
      };

    ompModel = slot: let
      model = models.${slot};
    in
      model
      // {inherit compat;}
      // lib.optionalAttrs model.reasoning {
        thinking = {
          mode = "anthropic-adaptive";
          efforts = ["minimal" "low" "medium" "high" "xhigh" "max"];
        };
      };

    mkProvider = mkModel: {
      inherit baseUrl;
      api = "anthropic-messages";
      # Resolved per request, not at activation.
      apiKey = "!${keyCommand}";
      # The gateway authenticates with a bearer token, not an x-api-key.
      authHeader = true;
      models = map mkModel ["opus" "sonnet" "haiku"];
    };

    piModels = builtins.toJSON {providers.lego-claude = mkProvider piModel;};
    ompModels = builtins.toJSON {providers.lego-claude = mkProvider ompModel;};

    # These files are the harness's own scratchpad as much as ours: /model
    # writes a picked default back. A store symlink would make that write fail,
    # so seed the file when absent and otherwise leave it be -- the same
    # treatment pi's agent .md files already get. Drift is then a deliberate
    # local edit rather than something HM silently reverts on every switch.
    seedJson = name: path: text: let
      source = pkgs.writeText name text;
    in
      lib.hm.dag.entryAfter ["writeBoundary"] ''
        if [ ! -e ${lib.escapeShellArg path} ]; then
          run mkdir -p ${lib.escapeShellArg (builtins.dirOf path)}
          run cp ${source} ${lib.escapeShellArg path}
          run chmod 600 ${lib.escapeShellArg path}
        fi
      '';

    # Not `export X="$(cmd)"`: that would swallow a failing lookup and hand
    # Claude Code an empty token, which surfaces as a confusing auth error
    # rather than the real one. Left unset on failure so the CLI says so.
    tokenLookup = ''
      if [ -z "''${ANTHROPIC_AUTH_TOKEN:-}" ]; then
        if _token="$(${keyCommand})"; then
          export ANTHROPIC_AUTH_TOKEN="$_token"
        fi
        unset _token
      fi
    '';

    home = config.home.homeDirectory;
  in {
    home.activation = {
      ompGatewayProvider = seedJson "omp-models.json" "${home}/.omp/agent/models.json" ompModels;
      piGatewayProvider = seedJson "pi-models.json" "${home}/.pi/agent/models.json" piModels;
      caveGatewayProvider = seedJson "cave-models.json" "${home}/.cave/agent/models.json" piModels;
    };

    # Claude Code takes the plain ANTHROPIC_* environment the vendor docs
    # prescribe -- the same variables, resolved the same way, as the agent-shell
    # that Emacs spawns (modules/doom.d/modules/tools/agent-shell/config.el:85).
    # Reusing that shape keeps one mechanism for this harness, not two.
    #
    # The docs pass the token as a value, which cannot be declared here: both
    # home.sessionVariables and a shell profile render into the world-readable
    # store, and ADR 0001 keeps the key out of it. So the lookup runs at process
    # start instead, the same trick the Darwin config uses for CHORUS_API_KEY
    # (modules/M-02877/dktaohan.nix:392). The value exists only in the
    # environment of the process about to spend it.
    #
    # A wrapper rather than shell init, because Home Manager does not own the
    # shell on mahakala: Guix Home does, and its bashrc returns early for
    # non-interactive shells (guix/bashrc:5-8), so an export there would miss
    # every agent spawned by Emacs, a timer, or another tool. The wrapper also
    # leaves ~/.claude/settings.json wholly to the user -- no settings layer, so
    # hooks, permissions and plugins keep working untouched.
    #
    # This replaces agents.claude-code in modules/shared-devtools.nix rather
    # than joining it: two derivations shipping bin/claude collide in one
    # profile. symlinkJoin keeps the rest of the package and swaps the
    # entrypoint. --set-default keeps every variable overridable from the
    # calling environment, so a one-off run against another model, or straight
    # at the gateway instead of through headroom, needs no edit here.
    home.packages = [
      (pkgs.symlinkJoin {
        name = "claude-code-gateway";
        paths = [agents.claude-code];
        nativeBuildInputs = [pkgs.makeWrapper];
        postBuild = ''
          rm "$out/bin/claude"
          makeWrapper ${lib.getExe' agents.claude-code "claude"} "$out/bin/claude" \
            --run ${lib.escapeShellArg tokenLookup} \
            --set-default ANTHROPIC_BASE_URL ${lib.escapeShellArg baseUrl} \
            --set-default ANTHROPIC_DEFAULT_OPUS_MODEL ${lib.escapeShellArg modelIds.opus} \
            --set-default ANTHROPIC_DEFAULT_SONNET_MODEL ${lib.escapeShellArg modelIds.sonnet} \
            --set-default ANTHROPIC_DEFAULT_HAIKU_MODEL ${lib.escapeShellArg modelIds.haiku} \
            --set-default ANTHROPIC_MODEL ${lib.escapeShellArg modelIds.opus} \
            --set-default ANTHROPIC_SMALL_FAST_MODEL ${lib.escapeShellArg modelIds.haiku}
        '';
      })
    ];
  };
}
