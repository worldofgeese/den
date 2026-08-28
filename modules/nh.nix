#
# nh wrappers, one per declared entity: `nix run .#paphos`, `nix run .#worldofgeese`.
#
# Derived from den.hosts/den.homes, so a new entry in modules/hosts.nix gains its
# wrapper with no edit here — the same property modules/checks.nix relies on.
#
# These do not replace the Justfile deploy recipes. Those carry substrate
# knowledge nh has no way to know: channel pull ordering on Guix,
# --use-remote-sudo against a remote aarch64 host, update-desktop-database after
# a mahakala switch. See the recipes for which is which.
#
# Refs: home-manager-757
{
  den,
  lib,
  ...
}: {
  perSystem = {pkgs, ...}: let
    # Hosts den declares but must not build carry `intoAttr = []` (pixel-fold).
    # den.lib.nh renders their wrapper as `nh os <action> .#` — the class defaults
    # to nixos and the attribute path is empty — which would run a NixOS switch
    # against nothing. Drop them rather than ship a wrapper that lies; the phone
    # is deployed with `just deploy-pixel-fold`.
    unbuilt =
      lib.concatMap
      (bySystem: lib.attrNames (lib.filterAttrs (_: host: host.intoAttr == []) bySystem))
      (lib.attrValues den.hosts);
  in {
    packages = lib.removeAttrs (den.lib.nh.denPackages {fromFlake = true;} pkgs) unbuilt;
  };
}
