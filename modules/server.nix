{ den, ... }:
{
  den.aspects.server.nixos = { pkgs, ... }: {
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    nix.gc.automatic = true;
    nix.gc.options = "--delete-older-than 8d";
    nixpkgs.config.allowUnfree = true;

    environment.systemPackages = with pkgs; [
      gitMinimal
      vim
    ];

    services.openssh.enable = true;
  };
}
