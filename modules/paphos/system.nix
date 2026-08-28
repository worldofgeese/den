{den, ...}: {
  den.aspects.paphos.nixos = {pkgs, ...}: let
    worldofgeeseGithubSshKeys = import ../_github-ssh-keys.nix pkgs;
    keys = import ./_keys.nix;
  in {
    system.stateVersion = "25.11";

    system.autoUpgrade = {
      enable = true;
      flake = "/etc/nixos#paphos";
      flags = [
        "--update-input"
        "nixpkgs"
        "--update-input"
        "forgesync"
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
