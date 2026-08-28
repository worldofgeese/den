#
# oracle: Oracle Cloud aarch64 NixOS host. Was built by a raw
# inputs.nixpkgs.lib.nixosSystem call in image.nix, outside den, so it was
# invisible from the registry and could not include a single shared aspect.
# Everything den.aspects.server and den.aspects.ssh-server centralise had been
# hand-copied here, and PermitRootLogin had already drifted from paphos.
#
# Its membership (server, ssh-server) is declared in modules/hosts.nix.
#
# Refs: home-manager-0pr.6
{
  den,
  inputs,
  ...
}: {
  den.aspects.oracle.nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    worldofgeeseGithubSshKeys = import ../_github-ssh-keys.nix pkgs;
  in {
    # Was a module-list entry on the retired nixosSystem call. den has no place
    # to pass extra NixOS modules for a host, and does not need one: a NixOS
    # module can import another.
    imports = ["${inputs.nixpkgs}/nixos/modules/virtualisation/oci-image.nix"];

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
      allowedTCPPorts = [22 80 443];
      # Tailscale peer relay (40000); Pangolin WireGuard (51820, 21820); Traefik QUIC (443)
      allowedUDPPorts = [443 21820 40000 51820];
      trustedInterfaces = ["tailscale0"];
    };

    # enable comes from den.aspects.ssh-server; the peer-relay flags are
    # oracle-only and stay here.
    services.tailscale = {
      # Peer relay only — no exit node or subnet router (useRoutingFeatures default "none")
      # Public IP 158.180.52.169 (2026-06-09). Update when OCI reserved IP changes; see docs/oracle/how-to-deploy-and-peer-relay.md.
      extraSetFlags = [
        "--relay-server-port=40000"
        "--relay-server-static-endpoints=158.180.52.169:40000"
      ];
    };

    services.pangolin = {
      enable = true;
      baseDomain = "geese.party";
      dashboardDomain = "pangolin.geese.party";
      letsEncryptEmail = "tao@linux.com";
      openFirewall = true;
      # Eval-only placeholder; runtime secrets in /var/lib/pangolin/pangolin.env (systemd override below).
      environmentFile = pkgs.writeText "pangolin-eval-placeholder.env" "# runtime: /var/lib/pangolin/pangolin.env\n";
      settings = {
        flags = {
          disable_signup_without_invite = true;
          disable_user_create_org = true;
          enable_integration_api = false;
        };
      };
    };

    systemd.services.pangolin.serviceConfig.EnvironmentFile = lib.mkForce [
      "-/var/lib/pangolin/pangolin.env"
    ];
    systemd.services.gerbil.serviceConfig.EnvironmentFile = lib.mkForce [
      "-/var/lib/pangolin/pangolin.env"
    ];

    # Jellyfin (jellyfin.geese.party) uses a Pangolin *local* site + HTTP resource
    # targeting mother.hound-celsius.ts.net:8096. Newt is not used on oracle because
    # Pangolin and the connector run on the same host (colocated hole-punch fails).

    systemd.tmpfiles.rules = [
      "d /var/lib/pangolin 0770 pangolin fossorial -"
      "f /var/lib/pangolin/pangolin.env 0600 pangolin fossorial -"
    ];

    # enable and PasswordAuthentication=false come from den.aspects.ssh-server.
    #
    # PermitRootLogin deliberately overrides that aspect's "no". This is a cloud
    # image with no console password and cloud-init disabled: oci-image.nix's
    # fetch-ssh-keys writes the instance-metadata key to /root/.ssh only, and the
    # postStart hook below copies it to the nixos user. Key-only root SSH is
    # therefore the break-glass path when the nixos user, sudo, or tailscale is
    # broken on a machine with no other way in. paphos keeps "no" because it has
    # local console access.
    services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";

    services.cloud-init = {
      enable = lib.mkForce false;
      network.enable = lib.mkForce false;
    };

    # oci-image.nix fetch-ssh-keys writes root keys only; append for nixos user.
    systemd.services.fetch-ssh-keys = {
      postStart = lib.mkAfter ''
        if [ -f /root/.ssh/authorized_keys ]; then
          install -d -m 700 -o nixos -g users /home/nixos/.ssh
          touch /home/nixos/.ssh/authorized_keys
          chown nixos:users /home/nixos/.ssh/authorized_keys
          chmod 600 /home/nixos/.ssh/authorized_keys
          while IFS= read -r key || [ -n "''${key}" ]; do
            [ -z "''${key}" ] && continue
            grep -qxF "''${key}" /home/nixos/.ssh/authorized_keys || echo "''${key}" >> /home/nixos/.ssh/authorized_keys
          done < /root/.ssh/authorized_keys
        fi
      '';
    };

    users.users.nixos = {
      isNormalUser = true;
      description = "Oracle Cloud bootstrap user";
      extraGroups = ["wheel"];
      openssh.authorizedKeys.keyFiles = [worldofgeeseGithubSshKeys];
    };

    security.sudo.wheelNeedsPassword = false;

    # nix.settings.experimental-features, nixpkgs.config.allowUnfree and nix.gc
    # come from den.aspects.server.

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
  };
}
