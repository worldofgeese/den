#!/usr/bin/env python3
"""Verify Home Manager profile activation across Nix command variants."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
EXPRESSION = """
let
  source = (builtins.getFlake (builtins.getEnv "WORKSPACE")).inputs.home-manager;
  config = {
    home.profileDirectory = builtins.getEnv "FAKE_PROFILE";
    home.path = "/nix/store/fake-home-manager-path";
    submoduleSupport.externalPackageInstall = builtins.getEnv "EXTERNAL" == "1";
  };
  lib = {
    mkForce = value: value;
    hm.dag.entryAfter = deps: data: { inherit data; after = deps; };
    hasInfix = needle: text: builtins.replaceStrings [ needle ] [ "" ] text != text;
    replaceStrings = builtins.replaceStrings;
    assertMsg = condition: message: if condition then true else throw message;
  };
  pkgs = {};
  baseline = (import "${source}/modules/home-environment.nix" {
    inherit config lib pkgs;
  }).config.home.activation.installPackages;
  module = import (builtins.toPath (builtins.getEnv "WORKSTATION_MODULE")) {
    den = {};
    inputs.home-manager = source;
  };
  result = module.den.aspects.workstation.homeManager { inherit config lib pkgs; };
in (result.home.activation.installPackages or baseline).data
"""

NIX_STUB = """\
#!/usr/bin/env bash
printf 'nix %s\\n' "$*" >>"$TRACE"
if [[ "$*" == 'profile add --help' ]]; then
  case ${SUPPORT:-yes} in
    yes) exit 0 ;;
    no) echo "error: 'add' is not a recognised command" >&2; exit 1 ;;
    error) echo 'error: could not read Nix configuration' >&2; exit 1 ;;
  esac
fi
if [[ "$*" == 'profile install /nix/store/fake-home-manager-path' \
      && ${SUPPORT:-yes} == yes ]]; then
  echo "warning: 'install' is a deprecated alias for 'add'" >&2
fi
if [[ ${FAIL_INSTALL:-0} == 1 ]]; then echo 'install failed' >&2; exit 1; fi
"""


class HomeProfileTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="home-profile-test-")
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name, body in {
            "nix": NIX_STUB,
            "nix-env": '#!/usr/bin/env bash\nprintf "nix-env %s\\n" "$*" >>"$TRACE"\n',
        }.items():
            executable = bin_dir / name
            executable.write_text(body)
            executable.chmod(0o755)
        self.profile = root / "profile"
        self.profile.mkdir()
        (self.profile / "manifest.json").write_text("{}")
        self.trace = root / "trace"
        self.env = os.environ | {
            "WORKSPACE": str(ROOT),
            "WORKSTATION_MODULE": str(ROOT / "modules/workstation.nix"),
            "FAKE_PROFILE": str(self.profile),
            "TRACE": str(self.trace),
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
        }

    def run_activation(self, **variables):
        env = self.env | variables
        # Use the real Nix for evaluation and the stub only for activation.
        eval_env = env | {"PATH": os.environ["PATH"]}
        script = subprocess.run(
            ["nix", "eval", "--extra-experimental-features", "nix-command flakes",
             "--impure", "--raw", "--expr", EXPRESSION],
            check=True,
            capture_output=True,
            text=True,
            env=eval_env,
        ).stdout
        prefix = """\
set -e
run() { "$@"; }
nixProfileRemove() { printf 'remove %s\\n' "$*" >>"$TRACE"; }
_iError() { printf '%s\\n' "$*" >&2; }
"""
        result = subprocess.run(
            ["bash", "-c", prefix + script], capture_output=True, text=True, env=env
        )
        calls = self.trace.read_text().splitlines() if self.trace.exists() else []
        return result, calls

    def test_modern_nix_uses_add_without_deprecation(self):
        result, calls = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(calls, [
            "nix profile add --help",
            "remove home-manager-path",
            "nix profile add /nix/store/fake-home-manager-path",
        ])

    def test_lix_falls_back_to_install(self):
        result, calls = self.run_activation(SUPPORT="no")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            "nix profile add --help",
            "remove home-manager-path",
            "nix profile install /nix/store/fake-home-manager-path",
        ])

    def test_probe_errors_do_not_remove_the_current_profile(self):
        result, calls = self.run_activation(SUPPORT="error")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not read Nix configuration", result.stderr)
        self.assertEqual(calls, ["nix profile add --help"])

    def test_install_failure_identifies_the_actual_command(self):
        result, calls = self.run_activation(FAIL_INSTALL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("install failed", result.stderr)
        self.assertIn("nix profile add", result.stderr)
        self.assertEqual(calls[-1], "nix profile add /nix/store/fake-home-manager-path")

    def test_legacy_nix_env_profile_is_unchanged(self):
        (self.profile / "manifest.json").unlink()
        result, calls = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["nix-env -i /nix/store/fake-home-manager-path"])

    def test_external_package_management_is_unchanged(self):
        result, calls = self.run_activation(EXTERNAL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["remove home-manager-path"])


if __name__ == "__main__":
    unittest.main()
