# crucible-llm (jkitchin/crucible) for whichever Python package set the caller
# passes; modules/shared-devtools.nix passes python315Packages. libsql is
# built from source because PyPI has no cp315 wheel. The leading underscore
# keeps import-tree from loading this file as a module.
{
  python3Packages,
  rustPlatform,
  cmake,
  git,
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
    # Runs upstream's suite whenever crucible-src, libsql-python-src or
    # nixpkgs-python315 moves. CI only evaluates, so a bump that breaks on this
    # Python fails at `just deploy`, before activation, and the installed
    # crucible keeps running against the wiki.
    # git: test_gitignore_actually_ignores_external_sources runs `git check-ignore`.
    nativeCheckInputs = [python3Packages.pytestCheckHook git];
    # Runs the CLI in a subprocess whose PYTHONPATH is only the source tree, so
    # it assumes click sits in the interpreter's own site-packages. Nix passes
    # dependencies through PYTHONPATH, so the import fails here.
    disabledTests = ["test_version_option_does_not_need_distribution_metadata"];
    # `crucible init` shells out to `crucible manifest`, so the tests need the
    # installed script on PATH.
    preCheck = ''
      export HOME=$(mktemp -d)
      export PATH=$out/bin:$PATH
    '';
    meta.mainProgram = "crucible";
  }
