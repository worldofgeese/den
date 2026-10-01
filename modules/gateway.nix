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
    #
    # secretspec's age provider starts age-plugin-se and asks the Secure
    # Enclave. pi resolves the key per request with a 10 s budget and turns
    # each miss into a failed turn.
    #
    # A locked screen is the confirmed cause of misses. The Secure Enclave
    # key's access control carries `ock` (usable only while the keybag is
    # unlocked), so every lookup fails from "AKS: Locked" to "AKS: Unlocked"
    # (ctkd: "unable to decapsulate shared key", e00002e2; secretspec reports
    # "No matching keys found"). Seen 2026-10-01 10:27-10:31, and again that
    # afternoon when an agent in flight lost its turn the moment the user
    # locked the screen. No retry survives that, so:
    #
    # Last-known-good cache. Every successful lookup refreshes
    # ~/.local/state/gateway-key.cache (0600, written only when the value
    # changes, renamed into place so a reader never sees half a key). A miss
    # serves the cache at once, without waiting through retries. secretspec
    # stays the source of truth: a rotated key reaches the cache on the next
    # unlocked lookup. The cache is plaintext at rest, like pr-reviewer's
    # key file (modules/M-02877/pr-reviewer.nix); FileVault covers it at rest.
    #
    # With no cache yet (first use, or after it is deleted), six attempts with
    # a growing backoff (0.5+1+1+1.5+2 = 6 s of sleep, inside the budget)
    # cover short transient misses only. Heavy CPU load was suspected for
    # some misses on 2026-10-01 but never confirmed.
    #
    # Every miss appends its error text and a timestamp line to
    # ~/.local/state/secretspec-gateway.log (the key goes to stdout only),
    # plus a line when the cache was served, so a miss can be lined up
    # against lock events (`log show --predicate 'process == "coreauthd"'`).
    # The final no-cache attempt leaves stderr alone so callers see the error.
    #
    # The string is embedded in JSON, a shell script and an elisp string
    # literal (doom.d agent-shell config.el), so it must contain no double
    # quote and no backslash.
    keyCommand = homeDirectory: let
      get = "secretspec get -f ${homeDirectory}/.config/home-manager/${facts.secret.profile} ${facts.secret.name} --reason 'model gateway auth for coding agent'";
      log = "${homeDirectory}/.local/state/secretspec-gateway.log";
      cache = "${homeDirectory}/.local/state/gateway-key.cache";
      stamp = what: "date '+%Y-%m-%dT%H:%M:%S%z ${what}' >>${log}";
      save = "echo $k | cmp -s - ${cache} 2>/dev/null || (umask 077; echo $k >${cache}.$$ && mv ${cache}.$$ ${cache})";
      try = redirect: "k=$(${get}${redirect}) && { ${save}; echo $k; exit 0; }";
    in
      "${try " 2>>${log}"}; ${stamp "miss"}; "
      + "[ -s ${cache} ] && { ${stamp "served cache"}; cat ${cache}; exit 0; }; "
      + "for d in 0.5 1 1 1.5; do sleep $d; ${try " 2>>${log}"}; ${stamp "miss"}; done; "
      + "sleep 2; ${try ""}; exit 1";
  };
}
