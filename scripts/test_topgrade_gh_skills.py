#!/usr/bin/env python3
"""Verify that the GitHub updater only touches skills it manages."""

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
    den = {};
    inputs = {};
  };
  settings = (workstation.den.aspects.workstation.homeManager {
    config = {}; pkgs = {}; lib = {};
  }).programs.topgrade.settings;
in settings.commands."GitHub CLI managed skills" or "gh skill update --all"
"""

GH_STUB = """\
#!/usr/bin/env bash
printf '%s\\0' "$@" >>"$TRACE"
printf '\\n' >>"$TRACE"
case "$1 $2" in
  'skill list')
    if [[ ${FAIL_LIST:-0} == 1 ]]; then echo 'inventory failed' >&2; exit 1; fi
    printf '%s\\n' "$INVENTORY"
    ;;
  'skill update')
    if [[ ${SKIP_RESOLVE:-0} == 1 ]]; then
      echo '! Skipping managed: could not resolve example/skills' >&2
      echo 'All skills are up to date.' >&2
      exit 0
    fi
    if [[ ${NO_SKILLS:-0} == 1 ]]; then echo 'No installed skills found.' >&2; exit 0; fi
    if [[ ${MISSING_REMOTE:-0} == 1 ]]; then
      echo 'All skills are up to date. Use --force without --dry-run to re-download anyway.' >&2
      exit 0
    fi
    if [[ " $* " == *' --dry-run '* ]]; then
      if [[ ${FAIL_CHECK:-0} == 1 ]]; then echo 'source check failed' >&2; exit 1; fi
      echo '1 update(s) available:' >&2
      echo '  managed (example/skills)  > abc123 [main]'
      exit 0
    fi
    if [[ ${FAIL_UPDATE:-0} == 1 ]]; then echo 'update failed' >&2; exit 1; fi
    if [[ "$*" == 'skill update --all' ]]; then
      echo 'unmanaged skill has no GitHub metadata' >&2
    fi
    ;;
  *) exit 2 ;;
esac
"""

JQ_STUB = """\
#!/usr/bin/env bash
if [[ $1 == --raw-output0 && ${FAIL_EXTRACTION:-0} == 1 ]]; then
  echo 'skill selection failed' >&2
  exit 1
fi
exec "$REAL_JQ" "$@"
"""


class GitHubSkillsTest(unittest.TestCase):
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

    def run_update(self, inventory, **variables):
        with tempfile.TemporaryDirectory(prefix="gh-skills-test-") as work:
            root = Path(work)
            inventory = [item.copy() for item in inventory]
            for item in inventory:
                skill = root / Path(item["path"]).relative_to("/tmp")
                skill.mkdir(parents=True, exist_ok=True)
                (skill / "SKILL.md").write_text("original skill")
                item["path"] = str(skill)
            executable = root / "gh"
            executable.write_text(GH_STUB)
            executable.chmod(0o755)
            jq = root / "jq"
            jq.write_text(JQ_STUB)
            jq.chmod(0o755)
            trace = root / "trace"
            env = os.environ | variables | {
                "PATH": f"{root}:{os.environ['PATH']}",
                "TRACE": str(trace),
                "INVENTORY": json.dumps(inventory),
                "REAL_JQ": shutil.which("jq"),
                "XDG_STATE_HOME": str(root / "state"),
            }
            result = subprocess.run(
                ["bash", "-c", self.command], capture_output=True, text=True, env=env
            )
            calls = [
                line.split("\0")[:-1]
                for line in trace.read_text().splitlines()
            ] if trace.exists() else []
            calls = [[arg.replace(str(root), "/tmp") for arg in call] for call in calls]
            backups = [
                path.read_text()
                for path in (root / "state").glob("den/skill-backups/*/*/*/SKILL.md")
            ]
            return result, calls, backups

    def test_only_unpinned_github_managed_skills_are_updated(self):
        inventory = [
            {"path": "/tmp/skills with space/managed", "sourceURL": "https://github.com/x/y", "pinned": False},
            {"path": "/tmp/skills/manual", "sourceURL": "", "pinned": False},
            {"path": "/tmp/skills/pinned", "sourceURL": "https://github.com/x/y", "pinned": True},
        ]
        result, calls, backups = self.run_update(inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(backups, ["original skill"])
        self.assertEqual(calls, [
            ["skill", "list", "--json", "path,sourceURL,pinned"],
            ["skill", "update", "--all", "--force", "--dry-run", "--dir", "/tmp/skills with space", "--", "managed"],
            ["skill", "update", "--all", "--dir", "/tmp/skills with space", "--", "managed"],
        ])

    def test_empty_inventory_succeeds_without_updating(self):
        result, calls, backups = self.run_update([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [["skill", "list", "--json", "path,sourceURL,pinned"]])
        self.assertEqual(backups, [])

    def test_inventory_failure_stops_updates(self):
        result, calls, backups = self.run_update([], FAIL_LIST="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("inventory failed", result.stderr)
        self.assertEqual(calls, [["skill", "list", "--json", "path,sourceURL,pinned"]])
        self.assertEqual(backups, [])

    def test_update_failure_is_not_hidden(self):
        inventory = [{"path": "/tmp/skills/managed", "sourceURL": "https://github.com/x/y", "pinned": False}]
        result, calls, backups = self.run_update(inventory, FAIL_UPDATE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("update failed", result.stderr)
        self.assertEqual(calls[-1][-1], "managed")
        self.assertEqual(backups, ["original skill"])

    def test_skipped_remote_resolution_is_not_reported_as_success(self):
        inventory = [{"path": "/tmp/skills/managed", "sourceURL": "https://github.com/x/y", "pinned": False}]
        result, calls, backups = self.run_update(inventory, SKIP_RESOLVE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Skipping managed: could not resolve", result.stderr)
        self.assertNotIn("All skills are up to date.", result.stderr)
        self.assertIn("Skill backups:", result.stdout)
        self.assertEqual(calls[-1][-1], "managed")
        self.assertEqual(backups, ["original skill"])

    def test_missing_selected_skill_is_not_reported_as_success(self):
        inventory = [{"path": "/tmp/skills/managed", "sourceURL": "https://github.com/x/y", "pinned": False}]
        result, calls, backups = self.run_update(inventory, NO_SKILLS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No installed skills found.", result.stderr)
        self.assertEqual(calls[-1][-1], "managed")
        self.assertEqual(backups, ["original skill"])

    def test_removed_source_skill_is_not_reported_as_current(self):
        inventory = [{"path": "/tmp/skills/managed", "sourceURL": "https://github.com/x/y", "pinned": False}]
        result, calls, backups = self.run_update(inventory, MISSING_REMOTE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verify", result.stderr)
        self.assertNotIn("All skills are up to date.", result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn("--dry-run", calls[-1])
        self.assertEqual(backups, ["original skill"])

    def test_failed_source_check_stops_before_update(self):
        inventory = [{"path": "/tmp/skills/managed", "sourceURL": "https://github.com/x/y", "pinned": False}]
        result, calls, backups = self.run_update(inventory, FAIL_CHECK="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source check failed", result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn("--dry-run", calls[-1])
        self.assertEqual(backups, ["original skill"])

    def test_selection_failure_does_not_report_success(self):
        inventory = [{"path": "/tmp/skills/managed", "sourceURL": "https://github.com/x/y", "pinned": False}]
        result, calls, backups = self.run_update(inventory, FAIL_EXTRACTION="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("skill selection failed", result.stderr)
        self.assertEqual(calls, [["skill", "list", "--json", "path,sourceURL,pinned"]])
        self.assertEqual(backups, [])


if __name__ == "__main__":
    unittest.main()
