{den, ...}: {
  den.aspects.paphos.nixos = {
    config,
    lib,
    pkgs,
    modulesPath,
    ...
  }: let
    keys = import ./_keys.nix;
  in {
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
        authorizedKeys = keys.remote;
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

    swapDevices = [
      {
        device = "/var/lib/swapfile";
        size = 2048;
      }
    ];

    zramSwap = {
      enable = true;
      memoryPercent = 25;
      algorithm = "zstd";
    };

    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
    hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  };
}
