{den, ...}: {
  den.aspects.ssh.homeManager = {
    config,
    lib,
    ...
  }: {
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
      settings = {
        "*" = {
          ControlMaster = "auto";
          ControlPersist = "yes";
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
          HostName = "158.180.52.169";
          User = "nixos";
        };
        pixel-fold = {
          HostName = "google-pixel-fold.hound-celsius.ts.net";
          Port = 8022;
          User = "nix-on-droid";
        };
        desktop = {
          HostName = "desktop-6071t21.hound-celsius.ts.net";
          User = "worldofgeese";
        };
      };
    };

    # https://github.com/nix-community/home-manager/issues/322
    # OpenSSH rejects config when the resolved symlink path traverses
    # group-writable directories (/nix/store is root:nixbld g+w).
    # Replace the symlink with a copy after link generation.
    home.file.".ssh/config".force = true;

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
