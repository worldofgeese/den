#
# The model gateway: one owner for how an agent reaches a model.
#
# Before this module, four sites each held the complete set of facts -- the
# launchd agents in modules/M-02877/darwin.nix, pi's models.json in
# modules/M-02877/dktaohan.nix, the Guix Home OCI service in
# guix/home-configuration.scm, and the agent-shell elisp -- and they had
# already drifted: HEADROOM_MODE was set on darwin and silently absent under
# Guix Home, so the two substrates ran different cache/cost tradeoffs.
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
      # darwin it goes through the proxy-chain network gateway IP, resolved
      # at runtime because container IPs are reassigned on restart
      # (modules/M-02877/darwin.nix). Those callers take `port` and build
      # their own URL.
      loopbackUrl = entity: "http://127.0.0.1:${toString (on entity).port}";
    };
in {
  _module.args.gateway = {
    inherit (facts) baseUrl;

    # headroom rewrites prior turns and forwards to the gateway's Claude
    # endpoint; pi talks to the Anthropic-compatible endpoint directly.
    claudeUrl = facts.baseUrl + facts.paths.claude;
    anthropicUrl = facts.baseUrl + facts.paths.anthropic;

    headroom = service "headroom";
    proxy = service "proxy";
    phoenix = service "phoenix";

    # One secret for every consumer, deliberately: per-harness virtual keys
    # were considered and rejected on 2026-08-01 (recorded in
    # home-manager-0pr.2) because one secret to set per host beat
    # per-virtual-key usage attribution in the gateway console.
    #
    # A command, never a value: callers embed this string and run it when an
    # agent process starts, so the key never enters the store or the tree.
    # pi's models.json prefixes it with `!` to mark it executable; the elisp
    # runs it through call-process-shell-command.
    secretName = facts.secret.name;
    keyCommand = homeDirectory: "secretspec get -f ${homeDirectory}/.config/home-manager/${facts.secret.profile} ${facts.secret.name}";
  };
}
