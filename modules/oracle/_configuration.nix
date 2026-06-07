{
  config,
  lib,
  pkgs,
  ...
}: {
  system.stateVersion = "25.11";

  # oci-image.nix imports make-disk-image with copyChannel=true by default;
  # nixos-install then copies full nixpkgs source into the qcow and OOMs under
  # qemu-binfmt cross-build on paphos.
  system.build.OCIImage = lib.mkForce (
    import "${pkgs.path}/nixos/lib/make-disk-image.nix" {
      inherit config lib pkgs;
      inherit (config.virtualisation) diskSize;
      name = "oci-image";
      baseName = config.image.baseName;
      configFile = pkgs.writeText "oci-config-user.nix" ''
        { modulesPath, ... }: {
          imports = [ "''${modulesPath}/virtualisation/oci-common.nix" ];
        }
      '';
      format = "qcow2";
      partitionTableType =
        if config.oci.efi
        then "efi"
        else "legacy";
      memSize = 4096;
      copyChannel = false;
    }
  );

  oci.efi = true;

  networking.hostName = "oracle";
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [22];
    # Tailscale peer relay (tailscale set --relay-server-port=40000)
    allowedUDPPorts = [40000];
    trustedInterfaces = ["tailscale0"];
  };

  services.tailscale = {
    enable = true;
    # Peer relay only — no exit node or subnet router (useRoutingFeatures default "none")
    extraSetFlags = ["--relay-server-port=40000"];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  services.cloud-init = {
    enable = lib.mkForce false;
    network.enable = lib.mkForce false;
  };

  # oci-image.nix fetch-ssh-keys writes root keys only; mirror for nixos user.
  systemd.services.fetch-ssh-keys = {
    postStart = lib.mkAfter ''
      if [ -f /root/.ssh/authorized_keys ]; then
        install -d -m 700 -o nixos -g users /home/nixos/.ssh
        cp /root/.ssh/authorized_keys /home/nixos/.ssh/authorized_keys
        chown nixos:users /home/nixos/.ssh/authorized_keys
        chmod 600 /home/nixos/.ssh/authorized_keys
      fi
    '';
  };

  users.users.nixos = {
    isNormalUser = true;
    description = "Oracle Cloud bootstrap user";
    extraGroups = ["wheel"];
  };

  security.sudo.wheelNeedsPassword = false;

  nix.settings.experimental-features = ["nix-command" "flakes"];
  nixpkgs.config.allowUnfree = true;

  # Rebuild from github:worldofgeese/den#oracle at committed flake.lock; no local checkout.
  system.autoUpgrade = {
    enable = true;
    flake = "github:worldofgeese/den#oracle";
    flags = [
      "--print-build-logs"
    ];
    dates = "04:00";
    randomizedDelaySec = "45min";
    allowReboot = true;
    rebootWindow = {
      lower = "04:00";
      upper = "05:00";
    };
  };

  nix.gc = {
    automatic = true;
    options = "--delete-older-than 8d";
  };

  nix.optimise.automatic = true;

  # Default nix.registry pins nixpkgs to pkgs.path in /etc/nix/registry.json;
  # etc closure then pulls full nixpkgs source into make-disk-image and OOMs
  # under qemu-binfmt cross-build even with copyChannel = false.
  nix.registry = lib.mkForce {};
  nix.nixPath = lib.mkForce [];
  nix.channel.enable = lib.mkForce false;

  # bash inputrc etc entry references a file under pkgs.path — same leak.
  environment.etc.inputrc.enable = lib.mkForce false;

  # Skip docs/manpages — expensive under qemu-binfmt cross-build on paphos.
  documentation.enable = false;
  documentation.nixos.enable = false;
  documentation.man.enable = false;
  documentation.man.man-db.enable = false;
  documentation.info.enable = false;
  documentation.doc.enable = false;

  environment.defaultPackages = lib.mkForce [];

  programs.nano.enable = lib.mkForce false;
  programs.command-not-found.enable = lib.mkForce false;

  system.disableInstallerTools = true;

  i18n.defaultLocale = lib.mkForce "C.UTF-8";
  i18n.extraLocales = lib.mkForce [];
  i18n.glibcLocales = lib.mkForce null;
}
