{ den, ... }:
{
  den.aspects.ssh.homeManager = {
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
