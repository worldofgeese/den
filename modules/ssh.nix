{ den, ... }:
{
  den.aspects.ssh.homeManager = { config, lib, ... }: {
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
      matchBlocks = {
        paphos = {
          hostname = "paphos.hound-celsius.ts.net";
          user = "kypris";
        };
        pixel-fold = {
          hostname = "google-pixel-fold.hound-celsius.ts.net";
          port = 8022;
          user = "nix-on-droid";
        };
        mother = {
          hostname = "mother";
          port = 2235;
          user = "taohansen";
        };
        openclaw = {
          hostname = "openclaw.hound-celsius.ts.net";
          user = "worldofgeese";
        };
      };
    };

    # https://github.com/nix-community/home-manager/issues/322
    # OpenSSH rejects config when the resolved symlink path traverses
    # group-writable directories (/nix/store is root:nixbld g+w).
    # Replace the symlink with a copy after link generation.
    home.file.".ssh/config".force = true;

    home.activation.installSSHConfig = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      run install -d -m 0700 "$HOME/.ssh"
      if [ -L "$HOME/.ssh/config" ]; then
        src="$(readlink -f "$HOME/.ssh/config")"
        run rm -f "$HOME/.ssh/config"
        run install -m 0600 "$src" "$HOME/.ssh/config"
      fi
    '';
  };

  den.aspects.ssh-server.nixos = { ... }: {
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
