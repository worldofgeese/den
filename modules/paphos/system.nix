{den, ...}: {
  den.aspects.paphos.nixos = {pkgs, ...}: let
    worldofgeeseGithubSshKeys = import ../_github-ssh-keys.nix pkgs;
    keys = import ./_keys.nix;
  in {
    system.stateVersion = "25.11";

    # Rebuild from the published repository, not from a checkout on paphos.
    #
    # This previously read `flake = "/etc/nixos#paphos"`, which made the weekly
    # run authoritative over whatever happened to be in /etc/nixos - a clone
    # pinned at 4adf67a (2026-05-07), 237 commits behind main. Every deploy from
    # a workstation was therefore reverted by the next Wednesday: the OpenClaw
    # container's SSH key was added to keys.local on 2026-09-01 and generation 78
    # (built 2026-09-02 03:42 by nixos-upgrade.service from the May tree) dropped
    # it again, breaking container -> kypris@paphos exactly as before.
    #
    # `--update-input` is gone with it: a github: ref has no writable lock, so
    # inputs advance when a new flake.lock is committed here. Same arrangement as
    # modules/oracle/system.nix, which has never had this problem.
    system.autoUpgrade = {
      enable = true;
      flake = "github:worldofgeese/den#paphos";
      flags = [
        "--print-build-logs"
      ];
      dates = "Wed 03:00";
      randomizedDelaySec = "30min";
      allowReboot = false;
    };

    users.users.kypris = {
      isNormalUser = true;
      description = "Loving Kypris";
      extraGroups = ["networkmanager" "wheel"];
      openssh.authorizedKeys.keyFiles = [worldofgeeseGithubSshKeys];
      openssh.authorizedKeys.keys = keys.remote ++ keys.local;
    };

    security.sudo.extraRules = [
      {
        users = ["kypris"];
        commands = [
          {
            command = "ALL";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];
  };
}
