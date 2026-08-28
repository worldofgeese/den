{
  lib,
  config,
  ...
}: let
  # Hashing the joined names forces each one explicitly. `home.packages` is a
  # `listOf package`, so the module system's type check already forces every
  # element -- verified by renaming an overlay attribute the lists consume
  # (`mcp-agent-mail`): the gate fails. The digest does not rely on that, and keeps
  # the report a fixed size.
  digest = names: builtins.hashString "sha256" (lib.concatStringsSep "," names);

  homePackages = hm: digest (map (p: p.name) hm.home.packages);

  # `x.y.z or default` also covers a missing intermediate attribute, which is how
  # a configuration with no Home Manager module (oracle) reports no users.
  hmUsers = cfg:
    lib.mapAttrsToList (user: hm: "${user} ${homePackages hm}")
    (cfg.config.home-manager.users or {});

  # unsafeDiscardStringContext is what keeps this a *check* rather than a build.
  # A store path inside a string carries context, so embedding toplevel.drvPath
  # verbatim would make the check derivation depend on the whole system closure:
  # `nix build .#checks.aarch64-darwin.M-02877` then builds all of M-02877.
  # Dropping the context keeps the path as evidence in the report while leaving
  # the check a dependency-free text file. Eval still forces the drvPath, which is
  # the whole point of the gate.
  systemReport = cfg:
    lib.concatStringsSep "\n" (
      [(builtins.unsafeDiscardStringContext cfg.config.system.build.toplevel.drvPath)]
      ++ hmUsers cfg
    );
  # The check is a text file, deliberately: writing the report forces every
  # package name at eval time without building any of them. See the note below.
  mkCheck = name: cfg: report:
    cfg.pkgs.runCommand "check-${name}" {} ''
      cat > $out <<'REPORT'
      ${report}
      REPORT
    '';

  entity = report: name: cfg: {
    inherit name cfg;
    system = cfg.pkgs.stdenv.hostPlatform.system;
    report = report cfg;
  };

  entities =
    lib.mapAttrsToList (entity systemReport) config.flake.nixosConfigurations
    ++ lib.mapAttrsToList (entity systemReport) config.flake.darwinConfigurations
    ++ lib.mapAttrsToList (entity (cfg: homePackages cfg.config)) config.flake.homeConfigurations
    ++ lib.mapAttrsToList
    (entity (cfg: homePackages cfg.config.home-manager.config))
    config.flake.nixOnDroidConfigurations;
in {
  # One gate over every entity the flake exposes, derived rather than typed: a new
  # den.hosts/den.homes entry (modules/hosts.nix) gains its check with no Justfile
  # edit.
  #
  # Published as real `flake.checks.<system>` so `nix flake check` covers it, not
  # only `just check`. Written here rather than as den's `checks` aspect class
  # (den.policies.checks-to-flake): that class hands an aspect `pkgs`, but a check
  # over a whole entity needs the *instantiated* configuration, which is only
  # reachable from the flake outputs. den's own templates/example/modules/tests.nix
  # reads inputs.self.nixosConfigurations for exactly this reason.
  #
  # Package names, not activation packages: doom-emacs builds via IFD, so forcing
  # activationPackage.drvPath for the worldofgeese home makes eval *build*
  # doom-intermediates, which needs a real x86_64-linux builder that is not
  # available on darwin. Forcing names still catches undefined variables and
  # missing package attributes. stateVersion, which this replaced for paphos,
  # oracle and pixel-fold, evaluates without ever touching the package list.
  #
  # This is why `just check` forces drvPaths instead of building the checks: the
  # report is cheap to evaluate on every system, and building it is only possible
  # for the local one.
  flake.checks =
    lib.mapAttrs
    (_: es: lib.listToAttrs (map (e: lib.nameValuePair e.name (mkCheck e.name e.cfg e.report)) es))
    (lib.groupBy (e: e.system) entities);
}
