{den, ...}: {
  den.aspects.paphos.nixos = {...}: let
    worldofgeeseGithubSshKeys = import ../_github-ssh-keys.nix;
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
    # nixpkgs follows the head of nixos-unstable at every run, not the committed
    # flake.lock. With only the lock, nixpkgs advanced when someone committed a
    # new lock, so in October 2026 both servers stayed on mid-October nixpkgs
    # through the Black October fixes (Node 22.23.4, the eMudhra root removal in
    # cacert 3.131.1, Forgejo security releases). nixos-unstable advances only
    # after Hydra's NixOS tests pass. A run that fails to build leaves the
    # running system in place, and paphos-health-check reports
    # nixos-upgrade-failed. Every other input stays at the committed lock. Same
    # arrangement as modules/oracle/system.nix.
    #
    # Daily, with reboots. allowReboot used to be false because the LUKS root
    # needed its passphrase over initrd SSH, so paphos ran kernel 7.0.3 for 175
    # days with 7.3 installed. The root now unlocks through Tang on mother
    # (hardware.nix). The window opens after mother's Monday 04:00 DSM update, so
    # Tang is up when paphos boots. The run must start inside the window: NixOS
    # checks it when the build finishes, and outside it skips the reboot and,
    # when the kernel changed, the switch too.
    system.autoUpgrade = {
      enable = true;
      flake = "github:worldofgeese/den#paphos";
      flags = [
        "--print-build-logs"
        "--override-input"
        "nixpkgs"
        "github:NixOS/nixpkgs/nixos-unstable"
      ];
      dates = "05:00";
      randomizedDelaySec = "20min";
      allowReboot = true;
      rebootWindow = {
        lower = "05:00";
        upper = "06:30";
      };
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
