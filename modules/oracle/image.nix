{config, ...}: {
  # nixosConfigurations.oracle is now built by den from den.hosts (see
  # modules/hosts.nix); this file only re-exports the disk image that
  # modules/oracle/system.nix builds. The output name is load-bearing:
  # terraform/oracle/variables.tf and `just build-oracle-image` both use it.
  flake.packages.aarch64-linux.oracle-image =
    config.flake.nixosConfigurations.oracle.config.system.build.OCIImage;
}
