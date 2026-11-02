# Records the den commit that each deploy target was built from.
#
# The deploy report (scripts/deploy-report.py, plan step P8) reads
# /etc/den-revision on each host. The file has three lines: the commit, the
# narHash of the flake source, and its lastModified time.
#
# paphos and oracle rebuild with `--override-input nixpkgs ...`. Nix then drops
# self.rev, but it keeps narHash and lastModified (measured on 2026-11-02). The
# report finds the main commit that has that commit time, and confirms it by
# its narHash. A build from a checkout with uncommitted edits records
# `<rev>-dirty`, which GitHub does not know, so the report names the host
# `den-revision-unknown` on purpose.
{inputs, ...}: let
  rev = inputs.self.rev or inputs.self.dirtyRev or "";
  narHash = inputs.self.narHash or "";
  lastModified = toString (inputs.self.lastModified or 0);
  record = {
    system.configurationRevision =
      if rev != ""
      then rev
      else "nar:${narHash}";
    environment.etc."den-revision".text = ''
      ${rev}
      ${narHash}
      ${lastModified}
    '';
  };
in {
  den.aspects.server.nixos = record;
  den.aspects.M-02877.darwin = record;
}
