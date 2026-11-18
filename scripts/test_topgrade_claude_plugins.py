#!/usr/bin/env python3
"""Verify Claude plugin maintenance without invoking conversation hooks."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
EXPRESSION = """
let
  workstation = import (builtins.toPath (builtins.getEnv "WORKSTATION_MODULE")) {
    den = {}; inputs = {};
  };
  settings = (workstation.den.aspects.workstation.homeManager {
    config = {}; pkgs = {}; lib = {};
  }).programs.topgrade.settings;
in settings.commands."Claude Code plugins" or "claude plugin marketplace update"
"""

CLAUDE_STUB = """\
#!/usr/bin/env bash
printf '%s\\0' "$@" >>"$TRACE"
printf '\\n' >>"$TRACE"
if [[ $1 != --bare ]]; then
  echo 'SessionEnd hook failed: Signet is stopped' >&2
  exit 0
fi
shift
case "$1 $2 $3" in
  'plugin marketplace update')
    if [[ ${FAIL_MARKETPLACE:-0} == 1 ]]; then echo 'marketplace failed' >&2; exit 1; fi ;;
  'plugin marketplace list') printf '%s\\n' "$MARKETPLACES" ;;
  'plugin list --json') printf '%s\\n' "$PLUGINS" ;;
  'plugin update '*)
    if [[ ${FAIL_PLUGIN:-} == "${*: -1}" ]]; then echo 'plugin update failed' >&2; exit 1; fi ;;
  *) exit 2 ;;
esac
"""

JQ_STUB = """\
#!/usr/bin/env bash
if [[ $1 == --raw-output0 && ${FAIL_EXTRACTION:-0} == 1 ]]; then
  echo 'plugin selection failed' >&2
  exit 1
fi
exec "$REAL_JQ" "$@"
"""


class ClaudePluginsTest(unittest.TestCase):
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

    def run_update(self, plugins, **variables):
        with tempfile.TemporaryDirectory(prefix="claude-plugin-test-") as work:
            root = Path(work)
            executable = root / "claude"
            executable.write_text(CLAUDE_STUB)
            executable.chmod(0o755)
            jq = root / "jq"
            jq.write_text(JQ_STUB)
            jq.chmod(0o755)
            trace = root / "trace"
            env = os.environ | variables | {
                "PATH": f"{root}:{os.environ['PATH']}",
                "TRACE": str(trace),
                "MARKETPLACES": json.dumps([{"name": "market"}]),
                "PLUGINS": json.dumps(plugins),
                "REAL_JQ": shutil.which("jq"),
            }
            result = subprocess.run(
                ["bash", "-c", self.command], capture_output=True, text=True, env=env
            )
            calls = [
                line.split("\0")[:-1]
                for line in trace.read_text().splitlines()
            ] if trace.exists() else []
            return result, calls

    def test_only_marketplace_plugins_are_updated_without_hooks(self):
        plugins = [
            {"id": "one@market", "scope": "user"},
            {"id": "local@skills-dir", "scope": "user"},
            {"id": "two@market", "scope": "user"},
        ]
        result, calls = self.run_update(plugins)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(calls, [
            ["--bare", "plugin", "marketplace", "update"],
            ["--bare", "plugin", "marketplace", "list", "--json"],
            ["--bare", "plugin", "list", "--json"],
            ["--bare", "plugin", "update", "--scope", "user", "--", "one@market"],
            ["--bare", "plugin", "update", "--scope", "user", "--", "two@market"],
        ])

    def test_marketplace_failure_stops_plugin_updates(self):
        result, calls = self.run_update([], FAIL_MARKETPLACE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("marketplace failed", result.stderr)
        self.assertEqual(calls, [["--bare", "plugin", "marketplace", "update"]])

    def test_plugin_failure_is_reported_after_other_updates(self):
        plugins = [
            {"id": "one@market", "scope": "user"},
            {"id": "two@market", "scope": "user"},
        ]
        result, calls = self.run_update(plugins, FAIL_PLUGIN="one@market")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("plugin update failed", result.stderr)
        self.assertEqual(calls[-1], [
            "--bare", "plugin", "update", "--scope", "user", "--", "two@market",
        ])

    def test_selection_failure_does_not_report_success(self):
        result, calls = self.run_update(
            [{"id": "one@market", "scope": "user"}], FAIL_EXTRACTION="1"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("plugin selection failed", result.stderr)
        self.assertEqual(calls, [
            ["--bare", "plugin", "marketplace", "update"],
            ["--bare", "plugin", "marketplace", "list", "--json"],
            ["--bare", "plugin", "list", "--json"],
        ])


if __name__ == "__main__":
    unittest.main()
