{den, ...}: {
  den.aspects.paphos.nixos = {
    config,
    lib,
    pkgs,
    modulesPath,
    ...
  }: {
    imports = [(modulesPath + "/installer/scan/not-detected.nix")];

    boot.initrd.availableKernelModules = ["xhci_pci" "ahci" "ehci_pci" "usbhid" "usb_storage" "sd_mod" "sdhci_pci" "igb"];
    boot.initrd.kernelModules = [];
    boot.kernelModules = ["kvm-amd"];
    boot.extraModulePackages = [];
    boot.kernelPackages = pkgs.linuxPackages_latest;
    boot.binfmt.emulatedSystems = ["aarch64-linux"];

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    boot.initrd.systemd.enable = true;

    boot.initrd.network = {
      enable = true;
      ssh = {
        enable = true;
        port = 2222;
        authorizedKeys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKmz+S865IyQMVYIxsCy7iezQ3oGdPQeumZtHd2zQ2E3 kypris"
          "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDiFcUsDjnI0HHY5+5vYZrqFRCYIV1jay2Yv2QXSOQdKgTOPDsvYIofnNqOsh9a6euNc4w7Uc5whc2ZAivYfQpu8hV9oU9gkdNK17k1wQ39akoplurXiQUFBs7dIVvArMxejPkBLbvwZUBQrkS5F8ldQkFSX+MVU+J+a6SVHQDcfnQMDzfvkSfy84zPxtL4cBtS81zNN8vwH8wIWdqZZMLqo8DiiYfHn4WU+TiPwSpTjKfcaQi8/2podOYlrRcthuiAj/adgTGJnCxXHLFWuYOhXq8ty1E6db/fqJB5/h8ZfQxI1BgTWvQZ7WolbRvJsnplaE0hmxSmdWvKx9YVYT8FO3JCBAqPFQGxYUfdtusTyy3Dix8uo9osRGV4IdQ+e1Vz4pehmbgyXuTH/efWE09vhMa5k5CPY61v7Y7voeK4XNUcNmppBt0xtgnzidjMVv7hbpplLQRLQR4T/oJ7z2cMzfgQJUrSL0EkH9JUEh8hmho9sy09W0O1YBRbRQGPs02fCmWNUJBpJU2ZR2E0L9eGTha6FA8aj5Hya6n+bpNUf8nFWpalrRbyN2KsrpcuZmnuZ91fwPP6DEL5XNC2UQHHp0sAENz8dAlZmFFqCK0RoF1sWRD+DvYdhkdjGg0toRZVcUJgQTzzbQ81zoEtw8jqKS9YfRHVWK3yAUo/j4ddIQ=="
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbIQYGvgicAePeJgXJY2wTFMjna8zHSIfqppFB0edOV"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAiVMF2Pv1UXd2rkxEgz1E7Wgdt8MXn4yDQ+/dSthrfy"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGQr88Pnz4YS8whUc6n2mtMeho/sNPqA9sDVzfAFxZH8"
        ];
        hostKeys = ["/etc/secrets/initrd/ssh_host_ed25519_key"];
      };
    };

    boot.initrd.systemd.network.enable = true;
    boot.initrd.systemd.network.networks."10-initrd" = {
      matchConfig.Name = "enp1s0";
      networkConfig.DHCP = "yes";
    };

    fileSystems."/" = {
      device = "/dev/mapper/luks-1c2d2926-91cd-4a86-a983-0e3b69ad2caa";
      fsType = "ext4";
    };

    boot.initrd.luks.devices."luks-1c2d2926-91cd-4a86-a983-0e3b69ad2caa".device = "/dev/disk/by-uuid/1c2d2926-91cd-4a86-a983-0e3b69ad2caa";

    fileSystems."/boot" = {
      device = "/dev/disk/by-uuid/5D87-7D1E";
      fsType = "vfat";
      options = ["fmask=0077" "dmask=0077"];
    };

    swapDevices = [];

    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
    hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  };
}
