#!/usr/bin/env python3
"""Exercise the plugin updater without modifying Hyprland state."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
EXPRESSION = """
let
  workstation = import (builtins.toPath (builtins.getEnv "WORKSTATION_MODULE")) {
    den = {};
    inputs = {};
  };
  settings = (workstation.den.aspects.workstation.homeManager { config = {}; pkgs = {}; lib = {}; })
    .programs.topgrade.settings;
in settings.commands."Hyprland plugins" or "hyprpm update"
"""

HYPRPM_STUB = """\
#!/usr/bin/env bash
printf '%s\\n' "$1" >>"$TRACE"
case $1 in
  list)
    if [[ ${FAIL_LIST:-0} == 1 ]]; then echo 'list failed' >&2; exit 1; fi
    if [[ ${FRESH_STATE:-0} == 1 ]]; then
      printf "\\033[0m\\342\\206\\222\\033[0m The hyprpm state store doesn't exist. Creating now...\\n"
    fi
    if [[ ${PLUGINS:-0} == 1 ]]; then
      printf '\\033[0m\\342\\206\\222\\033[0m Repository example (by author):\\n'
      printf '  \\342\\224\\202 Plugin example-plugin\\n'
      printf '  \\342\\224\\224\\342\\224\\200 enabled: \\033[31mfalse\\n\\033[0m\\n'
    fi
    if [[ ${UNEXPECTED_LIST:-0} == 1 ]]; then echo 'Unrecognized plugin state'; fi
    ;;
  update)
    if [[ ${PLUGINS:-0} != 1 ]]; then echo 'nothing to update' >&2; exit 1; fi
    if [[ ${FAIL_UPDATE:-0} == 1 ]]; then echo 'update failed' >&2; exit 1; fi
    ;;
  *) exit 2 ;;
esac
"""


class HyprpmUpdateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        env = os.environ | {"WORKSTATION_MODULE": str(ROOT / "modules/workstation.nix")}
        cls.command = subprocess.run(
            ["nix", "eval", "--extra-experimental-features", "nix-command",
             "--impure", "--raw", "--expr", EXPRESSION],
            check=True,
            capture_output=True,
            text=True,
            env=env,
        ).stdout

    def run_update(self, **variables):
        with tempfile.TemporaryDirectory(prefix="topgrade-hyprpm-test-") as work:
            root = Path(work)
            executable = root / "hyprpm"
            executable.write_text(HYPRPM_STUB)
            executable.chmod(0o755)
            trace = root / "trace"
            env = os.environ | variables | {
                "PATH": f"{root}:{os.environ['PATH']}",
                "TRACE": str(trace),
            }
            result = subprocess.run(
                ["bash", "-c", self.command], capture_output=True, text=True, env=env
            )
            return result, trace.read_text().splitlines() if trace.exists() else []

    def test_no_repositories_need_no_update(self):
        result, calls = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["list"])

    def test_initialization_message_does_not_trigger_update(self):
        result, calls = self.run_update(FRESH_STATE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No Hyprland plugin repositories", result.stdout)
        self.assertEqual(calls, ["list"])

    def test_unrecognized_output_is_reported_without_updating(self):
        result, calls = self.run_update(UNEXPECTED_LIST="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unrecognized plugin state", result.stderr)
        self.assertEqual(calls, ["list"])

    def test_initialization_does_not_hide_unrecognized_output(self):
        result, calls = self.run_update(FRESH_STATE="1", UNEXPECTED_LIST="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unrecognized plugin state", result.stderr)
        self.assertEqual(calls, ["list"])

    def test_registered_repositories_are_updated(self):
        result, calls = self.run_update(PLUGINS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["list", "update"])

    def test_listing_failure_is_reported(self):
        result, calls = self.run_update(FAIL_LIST="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("list failed", result.stderr)
        self.assertEqual(calls, ["list"])

    def test_update_failure_is_reported(self):
        result, calls = self.run_update(PLUGINS="1", FAIL_UPDATE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("update failed", result.stderr)
        self.assertEqual(calls, ["list", "update"])


if __name__ == "__main__":
    unittest.main()
