{
  den,
  oracleHost,
  ...
}: {
  den.aspects.ssh.homeManager = {
    config,
    lib,
    ...
  }: let
    # The pinned host keys. paphos's operations use the same file.
    hostKeys = import ./_host-keys.nix;
  in {
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
      settings = {
        "*" = {
          ControlMaster = "auto";
          ControlPersist = "yes";
          # The second file holds the pinned keys. ssh adds a newly seen key
          # to the first file only.
          UserKnownHostsFile = "~/.ssh/known_hosts ~/.ssh/known_hosts.den";
        };
        "github.com" = {
          HostName = "github.com";
          User = "git";
        };

        # --- Tailnet hosts (MagicDNS: *.hound-celsius.ts.net) ---
        loving-kypris = {
          HostName = "loving-kypris.hound-celsius.ts.net";
          User = "worldofgeese";
        };
        mahakala = {
          HostName = "mahakala.hound-celsius.ts.net";
          User = "worldofgeese";
        };
        paphos = {
          HostName = "paphos.hound-celsius.ts.net";
          User = "kypris";
        };
        mother = {
          HostName = "mother.hound-celsius.ts.net";
          Port = 2235;
          User = "taohansen";
        };
        oracle = {
          HostName = "oracle.hound-celsius.ts.net";
          User = "nixos";
        };
        "oracle-public" = {
          # oracle.json owns the public IP; terraform/oracle/reserved_ip.tf is its
          # upstream source of truth.
          HostName = oracleHost.publicIp;
          User = oracleHost.deployUser;
        };
        pixel-fold = {
          HostName = "google-pixel-fold.hound-celsius.ts.net";
          Port = 8022;
          User = "nix-on-droid";
        };
        desktop = {
          HostName = "desktop-6071t21.hound-celsius.ts.net";
          # The Windows account (whoami: desktop-6071t21\taoha).
          User = "taoha";
        };
      };
    };

    # https://github.com/nix-community/home-manager/issues/322
    # OpenSSH rejects config when the resolved symlink path traverses
    # group-writable directories (/nix/store is root:nixbld g+w).
    # Replace the symlink with a copy after link generation.
    home.file.".ssh/config".force = true;

    # The pinned keys, for the names that the aliases above connect to. On
    # 2026-10-30 `ssh oracle` failed with "Host key verification failed":
    # known_hosts had oracle's key only under its tailnet address. A pinned
    # host needs no first-use prompt, and a changed key fails the connection.
    # ssh reads a known-hosts file through a store link; only the config
    # file must be a copy.
    home.file.".ssh/known_hosts.den".text = ''
      paphos.hound-celsius.ts.net ${hostKeys.paphos}
      oracle.hound-celsius.ts.net,${oracleHost.publicIp} ${hostKeys.oracle}
    '';

    home.activation.installSSHConfig = lib.hm.dag.entryAfter ["linkGeneration"] ''
      run install -d -m 0700 "$HOME/.ssh"
      if [ -L "$HOME/.ssh/config" ]; then
        src="$(readlink -f "$HOME/.ssh/config")"
        run rm -f "$HOME/.ssh/config"
        run install -m 0600 "$src" "$HOME/.ssh/config"
      fi
    '';
  };

  den.aspects.ssh-server.nixos = {...}: {
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "no";
      };
    };
    services.tailscale.enable = true;
  };
}
