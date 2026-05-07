{ den, ... }:
{
  den.aspects.paphos.nixos = { ... }: {
    system.stateVersion = "25.11";

    system.autoUpgrade = {
      enable = true;
      flake = "/etc/nixos#paphos";
      flags = [
        "--update-input" "nixpkgs"
        "--update-input" "forgesync"
        "--print-build-logs"
      ];
      dates = "Wed 03:00";
      randomizedDelaySec = "30min";
      allowReboot = false;
    };

    users.users.kypris = {
      isNormalUser = true;
      description = "Loving Kypris";
      extraGroups = [ "networkmanager" "wheel" ];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKmz+S865IyQMVYIxsCy7iezQ3oGdPQeumZtHd2zQ2E3 kypris"
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDiFcUsDjnI0HHY5+5vYZrqFRCYIV1jay2Yv2QXSOQdKgTOPDsvYIofnNqOsh9a6euNc4w7Uc5whc2ZAivYfQpu8hV9oU9gkdNK17k1wQ39akoplurXiQUFBs7dIVvArMxejPkBLbvwZUBQrkS5F8ldQkFSX+MVU+J+a6SVHQDcfnQMDzfvkSfy84zPxtL4cBtS81zNN8vwH8wIWdqZZMLqo8DiiYfHn4WU+TiPwSpTjKfcaQi8/2podOYlrRcthuiAj/adgTGJnCxXHLFWuYOhXq8ty1E6db/fqJB5/h8ZfQxI1BgTWvQZ7WolbRvJsnplaE0hmxSmdWvKx9YVYT8FO3JCBAqPFQGxYUfdtusTyy3Dix8uo9osRGV4IdQ+e1Vz4pehmbgyXuTH/efWE09vhMa5k5CPY61v7Y7voeK4XNUcNmppBt0xtgnzidjMVv7hbpplLQRLQR4T/oJ7z2cMzfgQJUrSL0EkH9JUEh8hmho9sy09W0O1YBRbRQGPs02fCmWNUJBpJU2ZR2E0L9eGTha6FA8aj5Hya6n+bpNUf8nFWpalrRbyN2KsrpcuZmnuZ91fwPP6DEL5XNC2UQHHp0sAENz8dAlZmFFqCK0RoF1sWRD+DvYdhkdjGg0toRZVcUJgQTzzbQ81zoEtw8jqKS9YfRHVWK3yAUo/j4ddIQ=="
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbIQYGvgicAePeJgXJY2wTFMjna8zHSIfqppFB0edOV"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAiVMF2Pv1UXd2rkxEgz1E7Wgdt8MXn4yDQ+/dSthrfy"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGQr88Pnz4YS8whUc6n2mtMeho/sNPqA9sDVzfAFxZH8"
      ];
    };

    security.sudo.extraRules = [
      {
        users = [ "kypris" ];
        commands = [
          { command = "/run/current-system/sw/bin/nixos-rebuild"; options = [ "NOPASSWD" ]; }
        ];
      }
    ];
  };

  den.aspects.kypris = {
    includes = [ den.aspects.ssh ];
    homeManager = { ... }: {
      home.username = "kypris";
      home.homeDirectory = "/home/kypris";
      home.stateVersion = "25.11";
      programs.home-manager.enable = true;
    };
  };
}
