{
  lib,
  config,
  ...
}: let
  # Hashing the joined names forces each one explicitly. `home.packages` is a
  # `listOf package`, so the module system's type check already forces every
  # element -- verified: renaming the `br` overlay attribute fails this gate.
  # The digest does not rely on that, and keeps the output a fixed size.
  digest = names: builtins.hashString "sha256" (lib.concatStringsSep "," names);

  homePackages = hm: digest (map (p: p.name) hm.home.packages);

  # `x.y.z or default` also covers a missing intermediate attribute, which is how
  # a configuration with no Home Manager module (oracle) reports no users.
  systemEntity = cfg: {
    toplevel = cfg.config.system.build.toplevel.drvPath;
    users = lib.mapAttrs (_: homePackages) (cfg.config.home-manager.users or {});
  };
in {
  # One gate over every entity the flake exposes, derived rather than typed: a new
  # den.hosts/den.homes entry (modules/hosts.nix) gains its check with no Justfile
  # edit. `just check` forces this whole tree with a single `nix eval --json`.
  #
  # Package names, not activation packages: doom-emacs builds via IFD, so forcing
  # activationPackage.drvPath for the worldofgeese home makes eval *build*
  # doom-intermediates, which needs a real x86_64-linux builder that is not
  # available on darwin. Forcing names still catches undefined variables and
  # missing package attributes. stateVersion, which this replaces for paphos,
  # oracle and pixel-fold, evaluates without ever touching the package list.
  flake.evalChecks = {
    nixos = lib.mapAttrs (_: systemEntity) config.flake.nixosConfigurations;
    darwin = lib.mapAttrs (_: systemEntity) config.flake.darwinConfigurations;
    homes = lib.mapAttrs (_: cfg: homePackages cfg.config) config.flake.homeConfigurations;
    nixOnDroid = lib.mapAttrs (_: cfg: homePackages cfg.config.home-manager.config) config.flake.nixOnDroidConfigurations;
  };
}
