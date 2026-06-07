{inputs, ...}: let
  oracleNixOS = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      "${inputs.nixpkgs}/nixos/modules/virtualisation/oci-image.nix"
      ./_configuration.nix
    ];
  };
in {
  flake.nixosConfigurations.oracle = oracleNixOS;

  flake.packages.aarch64-linux.oracle-image =
    oracleNixOS.config.system.build.OCIImage;
}
