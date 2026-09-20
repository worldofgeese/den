#
# The model gateway: one owner for how an agent reaches a model.
#
# The facts live in ../gateway.json rather than here because Guile cannot
# import Nix. Both substrates read that one file; see
# docs/adr/0001-gateway-facts-cross-the-guix-seam-as-json.md for why the
# owner is data rather than a Nix attrset that generates data.
#
# This module is the Nix-side reader. It parses the facts once, derives the
# handful of values consumers would otherwise each re-derive (full URLs,
# per-entity publish specs, the key-lookup command), and injects the result
# as the `gateway` module argument so every Nix consumer becomes a thin
# adapter over it.
#
# Refs: home-manager-0pr.2
{lib, ...}: let
  facts = builtins.fromJSON (builtins.readFile ../gateway.json);

  # Published ports are keyed by entity, not by substrate, because the
  # difference is per-machine: 8787 is container-internal-only on M-02877
  # (published as 18787) but is also the host port on mahakala. Keying by
  # entity puts both readings side by side in gateway.json instead of
  # requiring a reader to already know which machine they are on.
  service = name: let
    raw = facts.${name};

    on = entity:
      raw.published.${entity}
      or (throw "gateway: ${name} has no published port for entity '${entity}'. Add one to gateway.json or stop reading it here.");

    # An empty host means "all interfaces" and renders as a bare port pair,
    # preserving `-p 18787:8787` exactly. A non-empty host renders the
    # three-part form Guix Home already used, `127.0.0.1:8787:8787`.
    # home-manager-zdo tracks whether M-02877 should also bind loopback-only:
    # that is a one-value change here rather than an edit in a shell string.
    publishSpec = entity: let
      p = on entity;
    in
      lib.optionalString (p.host != "") "${p.host}:"
      + "${toString p.port}:${toString raw.containerPort}";
  in
    raw
    // {
      inherit publishSpec;
      port = entity: (on entity).port;
      # How something already running on the host reaches this service.
      # Container-to-container addressing is deliberately not modelled: on
      # darwin it resolves the peer's container IP at runtime, because Apple
      # container has no inter-container DNS and its port forwarder answers
      # only loopback-originated requests, so neither a hostname nor the
      # published host port works from a sibling container
      # (modules/M-02877/darwin.nix carries the measurement). Container IPs
      # are reassigned on restart, which is why this is resolved per start
      # rather than modelled here. Those callers take `containerPort` and
      # build their own URL.
      loopbackUrl = entity: "http://127.0.0.1:${toString (on entity).port}";
    };
in {
  _module.args.gateway = {
    inherit (facts) baseUrl;

    # headroom rewrites prior turns and forwards to gateway's Claude endpoint.
    claudeUrl = facts.baseUrl + facts.paths.claude;

    # Pi appends /v1/messages itself, so an anthropic-messages provider must
    # stop at /anthropic rather than carry a version suffix. Named here so a
    # consumer does not re-derive the asymmetry the vendor docs warn about
    # (LEGO/ai-model-gateway-client, src/features/docs/pages/PiPage.tsx).
    anthropicUrl = facts.baseUrl + facts.paths.anthropic;

    # Model ids and their ceilings, one owner for every harness. The leading
    # `_`-prefixed keys in gateway.json are prose for humans; strip them so a
    # consumer can serialise a slot straight into a config file.
    models =
      builtins.mapAttrs
      (_: model: lib.filterAttrs (name: _: !lib.hasPrefix "_" name) model)
      facts.models;

    # Just the ids, for consumers that only name a slot (Claude Code's
    # ANTHROPIC_DEFAULT_*_MODEL, agent-shell's elisp substitutions).
    modelIds = builtins.mapAttrs (_: model: model.id) facts.models;

    headroom = service "headroom";
    proxy = service "proxy";
    phoenix = service "phoenix";

    # One secret for every consumer, deliberately: per-harness virtual keys
    # were considered and rejected on 2026-08-01 (recorded in
    # home-manager-0pr.2) because one secret to set per host beat
    # per-virtual-key usage attribution in gateway console.
    #
    # A command, never a value: callers embed this string and run it when an
    # agent process starts, so the key never enters the store or tree.
    secretName = facts.secret.name;
    keyCommand = homeDirectory: "secretspec get -f ${homeDirectory}/.config/home-manager/${facts.secret.profile} ${facts.secret.name} --reason 'model gateway auth for coding agent'";
  };
}
