#
# The membership registry: what every machine and user gets.
#
# Aspects elsewhere hold content only. Every edge that answers "what does this
# entity get?" lives here, beside the entity it affects, so one file answers the
# question instead of a chain through the files it affects least.
#
# Edges are written as `den.aspects.<entity>.includes` rather than
# `den.<hosts|homes>.….aspect.includes`: den defaults an entity's `aspect` to the
# aspect of the same name, and assigning `aspect.includes` REPLACES that default
# instead of extending it. Measured on 2026-08-27: worldofgeese's package list
# fell from 87 to 7 with no error, because its own aspect stopped being applied.
#
# Refs: home-manager-0pr.8
{den, ...}: {
  den.homes.x86_64-linux.worldofgeese = {};
  den.aspects.worldofgeese.includes = [
    den._.primary-user
    den.aspects.gitcommon
    den.aspects.workstation
    den.aspects.ssh
  ];

  den.hosts.aarch64-darwin.M-02877.users.dktaohan = {};
  den.aspects.dktaohan.includes = [
    den.batteries.define-user
    den.batteries.primary-user
    den.aspects.ssh
    den.aspects.sharedDevtools
    den.aspects.doom-emacs
    den.aspects.gitcommon
    den.aspects.terminal
  ];

  den.hosts.x86_64-linux.paphos.users.kypris = {};
  den.aspects.paphos.includes = [
    den.aspects.ssh-server
    den.aspects.server
  ];
  den.aspects.kypris.includes = [
    den.aspects.ssh
  ];

  den.hosts.aarch64-linux.oracle = {};
  den.aspects.oracle.includes = [
    den.aspects.ssh-server
    den.aspects.server
  ];
}
