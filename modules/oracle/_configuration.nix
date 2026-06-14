{
  config,
  lib,
  pkgs,
  ...
}: let
  worldofgeeseGithubSshKeys = import ../_github-ssh-keys.nix pkgs;
in {
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

  services.tailscale = {
    enable = true;
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

  # Low-priority synthetic CPU load — OCI Always Free idle reclaim mitigation.
  # See docs/oracle/reference-operations.md#anti-idle-cpu-load.
  systemd.services.oracle-anti-idle-cpu = {
    description = "Low-priority synthetic CPU load (OCI idle reclaim mitigation)";
    wantedBy = ["multi-user.target"];
    after = ["multi-user.target"];
    serviceConfig = {
      Type = "simple";
      Nice = 19;
      CPUWeight = 1;
      IOSchedulingClass = "idle";
      Restart = "always";
      RestartSec = "30s";
    };
    path = [pkgs.bash pkgs.coreutils pkgs.stress-ng];
    script = ''
      # Anti-reclaim: hit all three OCI Always Free idle thresholds (95th percentile
      # over 7 days, all must be < 20% to count as "idle").
      #   CPU:  40% of one core on 2-OCPU shape ≈ 20% total CPU.
      #   VM:   2.5 GB working set on 12 GB ≈ 21% memory utilization.
      #   Sock: 4 socket pairs to keep non-zero network activity (best-effort;
      #         sustained 20% of 1 Gbps interface is impractical for synthetic load).
      exec stress-ng \
        --cpu 1 --cpu-load 40 \
        --vm 1 --vm-bytes 2500M --vm-hang 0 \
        --sock 4 \
        --timeout 0
    '';
  };

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
