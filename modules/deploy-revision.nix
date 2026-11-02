# Records the den commit that each deploy target was built from.
#
# The deploy report (scripts/deploy-report.py, plan step P8) reads
# /etc/den-revision on each host and asks GitHub which commits of main are
# missing. paphos and oracle rebuild themselves from github:worldofgeese/den,
# so `self.rev` is the commit of main that they fetched. A build from a checkout
# with uncommitted edits records `<rev>-dirty`, which GitHub does not know. The
# report then names the host as `den-revision-unknown`, on purpose.
{inputs, ...}: let
  revision = inputs.self.rev or inputs.self.dirtyRev or "unknown";
  record = {
    system.configurationRevision = revision;
    environment.etc."den-revision".text = revision + "\n";
  };
in {
  den.aspects.server.nixos = record;
  den.aspects.M-02877.darwin = record;
}
