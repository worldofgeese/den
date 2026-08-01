#
# Tier routing: one owner for which model an agent tier runs on.
#
# Before this module the mapping was implemented twice, in two languages, at two
# lifecycle stages. modules/pi.nix held a tier table plus ~50 lines of embedded
# JavaScript that rewrote agent frontmatter during home.activation;
# modules/M-02877/dktaohan.nix held a second tier table, a build-time
# replaceStrings patcher, and a lib.mkForce on each of the seven agent files to
# get its patcher's output past the shared copy.
#
# Both patchers ran on the work profile -- modules/M-02877/dktaohan.nix includes
# den.aspects.pi and never disabled the activation script -- and the activation
# one ran last. So the build-time patcher was dead weight, which is provable
# rather than merely likely: running the activation script over the raw sources
# and over the build-patched sources yields byte-identical files, because it
# re-derives `model` from the same tier table it already owns and then rewrites
# the line regardless.
#
# The activation script was therefore the only thing deciding what landed on
# disk, on *both* profiles. This module reproduces its transform at build time
# and deletes it. Failures now surface during `nix eval` / `just check` instead
# of mid-activation on the machine, and an unknown tier or a missing model is a
# type error in the option below rather than a silently skipped file.
#
# The interface is a tier table plus a model catalogue. A profile contributes
# only a table; the transform is not a caller's concern.
#
# Refs: home-manager-0pr.3. See modules/gateway.nix for the same
# one-owner-several-consumers shape applied to gateway addressing.
{
  den,
  lib,
  ...
}: let
  agentOverrides = ../pi-extensions/agent-overrides;

  # Every override in the directory is routed. The two profiles previously
  # listed the same seven filenames each, which is the sort of duplication that
  # goes stale the first time an override is added.
  agentFileNames =
    builtins.attrNames
    (lib.filterAttrs
      (name: type: type == "regular" && lib.hasSuffix ".md" name)
      (builtins.readDir agentOverrides));

  # What the LEGO gateway serves.
  #
  # Model ids are routing, not addressing, so they deliberately stay out of
  # gateway.json -- see docs/adr/0001-gateway-facts-cross-the-guix-seam-as-json.md
  # and the model-id table in docs/solutions/proxy-chain-and-harness-auth.md.
  #
  # `slot` is Claude Code's vocabulary (opus / sonnet / haiku), which is how
  # agent-shell names models in its environment; pi addresses the same three
  # models by id through a models.json provider. One list owns both readings so
  # they cannot drift -- they already had, with the elisp pinned to a
  # `claude-opus-4-6-v1` generation the gateway had moved past.
  #
  # Metadata mirrors the gateway's own published catalogue (contextWindow,
  # maxTokens, data_zone pricing), not Anthropic list prices. home-manager-8vh
  # tracks a disagreement with the hand-written copy in ~/.cave/agent/models.json
  # on mahakala.
  gatewayCatalogue = [
    {
      slot = "opus";
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
      slot = "sonnet";
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
      slot = "haiku";
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

  # Reproduces, byte for byte, what the deleted activation script did: strip any
  # model:/thinking: line out of the frontmatter and re-insert the tier's values
  # immediately after `description: `. That is why `thinking` ends up *above*
  # `fallbackModels` in the result rather than where the source file has it.
  # Preserving that ordering is the point -- it is what is already on disk on
  # both machines, so reproducing it is what makes this refactor invisible.
  #
  # One behaviour is deliberately not carried over: the script also dropped body
  # lines that exactly equalled a value it was about to insert. The body begins
  # after the only `---` pair in these files, so no such line has ever existed
  # and the filter was unreachable. Reproducing it would be cargo cult.
  patchAgent = tiers: name: let
    content = builtins.readFile (agentOverrides + "/${name}");
    lines = lib.splitString "\n" content;
    afterOpen = builtins.tail lines;
    closeIdx = lib.lists.findFirstIndex (l: l == "---") null afterOpen;

    frontmatter = lib.take closeIdx afterOpen;
    body = lib.drop (closeIdx + 1) afterOpen;

    # Agents without a `tier:` field fall back to "execution", as they always
    # have. The prefix is matched without a space for the same reason the script
    # did: `tier:orchestrator` should not silently become the default tier.
    tierLine = lib.findFirst (lib.hasPrefix "tier:") null frontmatter;
    tierName =
      if tierLine != null
      then lib.trim (lib.removePrefix "tier:" tierLine)
      else "execution";
    tier = tiers.${tierName} or null;

    kept =
      builtins.filter
      (l: !(lib.hasPrefix "model:" l || lib.hasPrefix "thinking:" l))
      frontmatter;

    inserted =
      ["model: ${tier.model}"]
      ++ lib.optional (tier.thinking != null && tier.thinking != "") "thinking: ${tier.thinking}";

    descIdx = lib.lists.findFirstIndex (lib.hasPrefix "description: ") null kept;
    patched =
      if descIdx != null
      then lib.take (descIdx + 1) kept ++ inserted ++ lib.drop (descIdx + 1) kept
      else kept ++ inserted;
  in
    # A file with no frontmatter block, or naming a tier the table does not
    # define, passes through untouched -- again matching the script. `||`
    # short-circuits, so `frontmatter` is never forced when there is no closing
    # delimiter to slice at.
    if builtins.head lines != "---" || closeIdx == null || tier == null
    then content
    else lib.concatStringsSep "\n" (["---"] ++ patched ++ ["---"] ++ body);
in {
  # Exposed as a module argument rather than as an aspect attribute because den
  # aspects are freeform submodules: any key it does not recognise is read as a
  # *child aspect*, not as data. modules/gateway.nix establishes the pattern.
  _module.args.piTiers = {
    # For consumers that address a model by role instead of by id -- currently
    # the agent-shell elisp, which modules/doom-emacs.nix substitutes these into
    # so that no model id is ever a literal in tracked elisp.
    slots = lib.listToAttrs (map (m: lib.nameValuePair m.slot m.id) gatewayCatalogue);

    # pi's models.json `models` list: the same catalogue minus `slot`, which
    # means nothing to pi. Order is preserved because it is the order pi's
    # `/model` picker shows.
    models = map (m: builtins.removeAttrs m ["slot"]) gatewayCatalogue;
  };

  den.aspects.piTiers.homeManager = {config, ...}: let
    cfg = config.pi.tiers;
  in {
    options.pi.tiers.tiers = lib.mkOption {
      description = ''
        Tier name -> how agents in that tier are routed. Exactly one profile
        contributes one table; there is deliberately no default, so a machine
        that opts into den.aspects.pi without declaring a routing policy fails
        at eval instead of shipping an empty tier-defs.json.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          model = lib.mkOption {
            type = lib.types.str;
            description = ''
              Provider-qualified model id, e.g. "cursor/composer-latest" or
              "anthropic-proxy/eu.anthropic.claude-opus-5". The provider half is
              a models.json provider name on profiles that declare one.
            '';
          };
          thinking = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Value stamped into the agent's `thinking:` frontmatter field.";
          };
          fallbackModels = lib.mkOption {
            type = lib.types.nullOr (lib.types.listOf lib.types.str);
            default = null;
            description = ''
              Emitted into tier-defs.json only when set. Null on profiles that
              have never declared fallbacks, so their tier-defs.json keeps the
              exact two-key shape already on disk there.
            '';
          };
        };
      });
    };

    config.home.file =
      {
        # Kept at this path: read at runtime, and the only file here whose name
        # is part of anything else's interface.
        ".pi/agent/tier-defs.json".text = builtins.toJSON (
          lib.mapAttrs (_: tier:
            {inherit (tier) model;}
            // lib.optionalAttrs (tier.thinking != null) {inherit (tier) thinking;}
            // lib.optionalAttrs (tier.fallbackModels != null) {inherit (tier) fallbackModels;})
          cfg.tiers
        );
      }
      // lib.listToAttrs (map (name:
        lib.nameValuePair ".pi/agent/agents/${name}" {
          text = patchAgent cfg.tiers name;
          # Existing deployments have *regular files* at these paths: the
          # activation script this module replaces rewrote the symlinks in
          # place so it could patch them. Home Manager refuses to clobber an
          # unmanaged regular file, so `force` has to outlive the script by at
          # least one switch on each machine.
          force = true;
        })
      agentFileNames);
  };
}
