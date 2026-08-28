#
# The Nix-side reader for ../../oracle.json, injected as the `oracleHost` module
# argument so every consumer becomes a thin adapter over one file. Same shape and
# reasoning as modules/gateway.nix; see
# docs/adr/0001-gateway-facts-cross-the-guix-seam-as-json.md for why the owner is
# data rather than a Nix attrset.
#
# Before this, 158.180.52.169 was typed in three places that did not reference each
# other: the deploy-oracle defaults, oracle's tailscale relay endpoint, and the
# oracle-public SSH host.
#
# Refs: home-manager-0pr.10
{...}: let
  facts = builtins.fromJSON (builtins.readFile ../../oracle.json);
in {
  _module.args.oracleHost =
    facts
    // {
      # What tailscale advertises as the peer-relay endpoint.
      relayEndpoint = "${facts.publicIp}:${toString facts.relayPort}";
      # What nixos-rebuild and ssh connect to.
      sshTarget = "${facts.deployUser}@${facts.publicIp}";
    };
}
