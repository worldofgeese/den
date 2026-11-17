# crucible-llm (jkitchin/crucible) for whichever Python package set the caller
# passes; modules/shared-devtools.nix passes python315Packages. libsql is
# built from source because PyPI has no cp315 wheel. The leading underscore
# keeps import-tree from loading this file as a module.
{
  python3Packages,
  rustPlatform,
  cmake,
  crucibleSrc,
  libsqlSrc,
}: let
  libsql = python3Packages.buildPythonPackage {
    pname = "libsql";
    version = "0.1.11-unstable-${libsqlSrc.shortRev}";
    pyproject = true;
    src = libsqlSrc;
    cargoDeps = rustPlatform.importCargoLock {lockFile = "${libsqlSrc}/Cargo.lock";};
    nativeBuildInputs = [rustPlatform.cargoSetupHook rustPlatform.maturinBuildHook cmake];
    # cmake is for libsql-ffi's build script, not for configuring this package.
    dontUseCmakeConfigure = true;
    pythonImportsCheck = ["libsql"];
  };
in
  python3Packages.buildPythonApplication {
    pname = "crucible-llm";
    version = "0-unstable-${crucibleSrc.shortRev}";
    pyproject = true;
    src = crucibleSrc;
    build-system = [python3Packages.hatchling];
    dependencies = [python3Packages.click python3Packages.filelock libsql];
    pythonImportsCheck = ["crucible"];
    # Runs upstream's suite on each `nix flake update`, so a crucible or libsql
    # bump that breaks on this Python fails the build instead of the wiki.
    nativeCheckInputs = [python3Packages.pytestCheckHook];
    # `crucible init` shells out to `crucible manifest`, so the tests need the
    # installed script on PATH.
    preCheck = ''
      export HOME=$(mktemp -d)
      export PATH=$out/bin:$PATH
    '';
    meta.mainProgram = "crucible";
  }
