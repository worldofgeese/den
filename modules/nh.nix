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
{den, ...}: {
  perSystem = {pkgs, ...}: {
    packages = den.lib.nh.denPackages {fromFlake = true;} pkgs;
  };
}
