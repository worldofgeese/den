#!/usr/bin/env python3
"""Exercise global skill updates without changing the live home directory."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LOCK = json.dumps({"version": 3, "skills": {}})
EXPRESSION = """
let
  workstation = import (builtins.toPath (builtins.getEnv "WORKSTATION_MODULE")) {
    den = {};
    inputs = {};
  };
  settings = (workstation.den.aspects.workstation.homeManager {
    config = {}; pkgs = {}; lib = {};
  }).programs.topgrade.settings;
in {
  disabled = settings.misc.disable;
  command = settings.commands."Agent skills" or "";
}
"""

FAKE_LIBRARY = """\
export function getSupportedAgents() {
  if (process.env.INVALID_INVENTORY === 'empty') return [];
  if (process.env.INVALID_INVENTORY) return null;
  return JSON.parse(process.env.AGENT_ROOTS).map(globalSkillsDir => ({ globalSkillsDir }));
}
"""

FAKE_UPDATER = """\
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

writeFileSync(process.env.TRACE, JSON.stringify(process.argv.slice(2)));
for (const root of JSON.parse(process.env.MUTATE_ROOTS)) {
  const skill = join(root, 'fixture');
  rmSync(skill, { recursive: true, force: true });
  mkdirSync(skill, { recursive: true });
  writeFileSync(join(skill, 'SKILL.md'), 'updated');
}
writeFileSync(process.env.LOCK_PATH, 'updated lock');
if (process.env.UPDATE_REPORT === 'source') {
  process.stdout.write('\\x1b[2m✗ Failed to check skills from git://fixture\\x1b[0m\\n');
  process.stdout.write('✓ All global skills are up to date\\n');
} else if (process.env.UPDATE_REPORT === 'target') {
  process.stderr.write('\\x1b[2m✗ claude-code: permission denied\\x1b[0m\\n');
} else if (process.env.UPDATE_REPORT === 'current') {
  process.stdout.write('✓ All global skills are up to date\\n');
} else if (process.env.UPDATE_REPORT === 'warning') {
  process.stdout.write('\\x1b[2mWarning:\\x1b[0m Multiple current paths match these skills\\n');
  process.stdout.write('✓ All global skills are up to date\\n');
} else if (process.env.UPDATE_REPORT === 'uncheckable') {
  process.stdout.write('\\x1b[2m1 skill(s) cannot be checked automatically:\\x1b[0m\\n');
}
process.exitCode = Number(process.env.UPDATE_EXIT || '0');
"""


class AgentSkillsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        env = os.environ | {"WORKSTATION_MODULE": str(ROOT / "modules/workstation.nix")}
        result = subprocess.run(
            ["nix", "eval", "--extra-experimental-features", "nix-command",
             "--impure", "--json", "--expr", EXPRESSION],
            check=True,
            capture_output=True,
            text=True,
            env=env,
        )
        cls.settings = json.loads(result.stdout)

    def run_update(self, *, use_npx=False, invalid_inventory=False,
                   blocked_backup=False, update_exit=0, use_xdg=True,
                   overlap_backup=False, relative_state=False, update_report="",
                   lock_content=DEFAULT_LOCK):
        self.assertTrue(self.settings["command"], "Topgrade must use a guarded Agent skills step")
        with tempfile.TemporaryDirectory(prefix="agent-skills-test-") as work:
            root = Path(work)
            home = root / "home"
            canonical = home / ".agents" / "skills"
            real_agent = root / "other-agent-skills"
            agent = home / ".claude" / "skills"
            for directory in (canonical / "fixture", real_agent / "fixture", agent.parent):
                directory.mkdir(parents=True)
            agent.symlink_to(real_agent, target_is_directory=True)
            (canonical / "fixture" / "SKILL.md").write_text("canonical edit")
            (canonical / "fixture" / "LOCAL_ONLY").write_text("canonical local")
            (canonical / "fixture" / "reference").write_text("reference")
            (canonical / "fixture" / "reference-link").symlink_to("reference")
            (real_agent / "fixture" / "SKILL.md").write_text("agent edit")
            (real_agent / "fixture" / "LOCAL_ONLY").write_text("agent local")

            if overlap_backup:
                state = canonical
            elif relative_state:
                state = root / "relative-state"
            else:
                state = root / "state" if use_xdg else home / ".local" / "state"
            lock = state / "skills" / ".skill-lock.json" if use_xdg else home / ".agents" / ".skill-lock.json"
            lock.parent.mkdir(parents=True, exist_ok=True)
            lock.write_text(lock_content)
            if blocked_backup:
                state.mkdir(parents=True, exist_ok=True)
                (state / "den").write_text("not a directory")

            package = root / "package"
            (package / "bin").mkdir(parents=True)
            (package / "dist").mkdir()
            (package / "package.json").write_text(json.dumps({
                "name": "skills",
                "exports": {".": {"default": "./dist/index.mjs"}},
                "bin": {"skills": "./bin/cli.mjs"},
            }))
            (package / "dist" / "index.mjs").write_text(FAKE_LIBRARY)
            executable = package / "bin" / "cli.mjs"
            executable.write_text(f"#!{shutil.which('node')}\n" + FAKE_UPDATER)
            executable.chmod(0o755)
            (package / "bin" / "skills").symlink_to(executable)

            bin_dir = root / "bin"
            bin_dir.mkdir()
            (bin_dir / "node").symlink_to(shutil.which("node"))
            if not use_npx:
                (bin_dir / "skills").symlink_to(executable)
            npx = bin_dir / "npx"
            npx.write_text(
                f"#!{shutil.which('sh')}\n"
                'printf "%s\\n" "$*" > "$NPX_TRACE"\n'
                '[ "$1" = "--yes" ] && [ "$2" = "--package=skills" ] && [ "$3" = "--" ] || exit 80\n'
                'shift 3\n'
                'PATH="$PACKAGE_BIN:$PATH" exec "$@"\n'
            )
            npx.chmod(0o755)

            trace = root / "trace"
            npx_trace = root / "npx-trace"
            env = os.environ | {
                "HOME": str(home),
                "PATH": str(bin_dir),
                "TRACE": str(trace),
                "NPX_TRACE": str(npx_trace),
                "PACKAGE_BIN": str(package / "bin"),
                "AGENT_ROOTS": json.dumps([str(canonical), str(agent), str(real_agent), str(root / "absent")]),
                "MUTATE_ROOTS": json.dumps([str(canonical), str(agent)]),
                "LOCK_PATH": str(lock),
                "UPDATE_EXIT": str(update_exit),
                "UPDATE_REPORT": update_report,
            }
            if use_xdg:
                env["XDG_STATE_HOME"] = "relative-state" if relative_state else str(state)
            else:
                env.pop("XDG_STATE_HOME", None)
            if invalid_inventory:
                env["INVALID_INVENTORY"] = str(invalid_inventory)
            result = subprocess.run(
                shlex.split(self.settings["command"]),
                capture_output=True,
                text=True,
                env=env,
                cwd=root,
            )
            runs = list((state / "den" / "skill-backups").glob("skills-*")) if not blocked_backup else []
            saved = {}
            saved_lock = None
            private_mode = None
            if len(runs) == 1 and (runs[0] / "manifest.json").is_file():
                private_mode = runs[0].stat().st_mode & 0o777
                manifest = json.loads((runs[0] / "manifest.json").read_text())
                for item in manifest["roots"]:
                    snapshot = runs[0] / item["snapshot"] / "fixture"
                    saved[item["source"]] = {
                        "skill": (snapshot / "SKILL.md").read_text(),
                        "local": (snapshot / "LOCAL_ONLY").read_text(),
                        "link": os.readlink(snapshot / "reference-link")
                        if (snapshot / "reference-link").is_symlink() else None,
                    }
                saved_lock = (runs[0] / manifest["lock"]["snapshot"]).read_text()

            return {
                "result": result,
                "trace": json.loads(trace.read_text()) if trace.exists() else None,
                "npx": npx_trace.read_text() if npx_trace.exists() else None,
                "saved": saved,
                "saved_lock": saved_lock,
                "canonical": str(canonical.resolve()),
                "agent": str(real_agent.resolve()),
                "current": (canonical / "fixture" / "SKILL.md").read_text(),
                "mode": private_mode,
            }

    def test_guard_replaces_the_builtin_skills_step(self):
        self.assertIn("skills", self.settings["disabled"])
        self.assertTrue(self.settings["command"])

    def test_backup_covers_canonical_agent_symlink_and_xdg_lock(self):
        outcome = self.run_update()
        self.assertEqual(outcome["result"].returncode, 0, outcome["result"].stderr)
        self.assertEqual(outcome["trace"], ["update", "--global", "--yes"])
        self.assertEqual(outcome["saved"][outcome["canonical"]], {
            "skill": "canonical edit", "local": "canonical local", "link": "reference",
        })
        self.assertEqual(outcome["saved"][outcome["agent"]], {
            "skill": "agent edit", "local": "agent local", "link": None,
        })
        self.assertEqual(len(outcome["saved"]), 2)
        self.assertEqual(outcome["saved_lock"], DEFAULT_LOCK)
        self.assertEqual(outcome["current"], "updated")
        self.assertEqual(outcome["mode"], 0o700)

    def test_failed_backup_does_not_run_the_updater(self):
        outcome = self.run_update(blocked_backup=True)
        self.assertNotEqual(outcome["result"].returncode, 0)
        self.assertIsNone(outcome["trace"])
        self.assertEqual(outcome["current"], "canonical edit")

    def test_invalid_inventory_does_not_run_the_updater(self):
        for inventory in (True, "empty"):
            with self.subTest(inventory=inventory):
                outcome = self.run_update(invalid_inventory=inventory)
                self.assertNotEqual(outcome["result"].returncode, 0)
                self.assertIsNone(outcome["trace"])
                self.assertEqual(outcome["current"], "canonical edit")

    def test_backup_inside_a_skill_root_does_not_run_the_updater(self):
        outcome = self.run_update(overlap_backup=True)
        self.assertNotEqual(outcome["result"].returncode, 0)
        self.assertIn("overlaps", outcome["result"].stderr)
        self.assertIsNone(outcome["trace"])
        self.assertEqual(outcome["current"], "canonical edit")

    def test_relative_state_directory_does_not_run_the_updater(self):
        outcome = self.run_update(relative_state=True)
        self.assertNotEqual(outcome["result"].returncode, 0)
        self.assertIn("XDG_STATE_HOME", outcome["result"].stderr)
        self.assertIsNone(outcome["trace"])
        self.assertEqual(outcome["current"], "canonical edit")

    def test_updater_failure_retains_the_backup_and_exit_status(self):
        outcome = self.run_update(update_exit=17)
        self.assertEqual(outcome["result"].returncode, 17)
        self.assertEqual(outcome["saved_lock"], DEFAULT_LOCK)
        self.assertEqual(outcome["saved"][outcome["canonical"]]["local"], "canonical local")

    def test_npx_fallback_uses_the_same_guard(self):
        outcome = self.run_update(use_npx=True)
        self.assertEqual(outcome["result"].returncode, 0, outcome["result"].stderr)
        self.assertIn("--package=skills", outcome["npx"])
        self.assertEqual(outcome["saved"][outcome["agent"]]["local"], "agent local")

    def test_backup_uses_the_legacy_lock_when_xdg_state_is_unset(self):
        outcome = self.run_update(use_xdg=False)
        self.assertEqual(outcome["result"].returncode, 0, outcome["result"].stderr)
        self.assertEqual(outcome["saved_lock"], DEFAULT_LOCK)

    def test_silently_uncheckable_skills_do_not_report_success(self):
        lock = json.dumps({"version": 3, "skills": {
            "checked": {"sourceType": "github", "skillPath": "SKILL.md", "skillFolderHash": "abc"},
            "missing-hash": {"sourceType": "github", "skillPath": "SKILL.md"},
            "missing-path": {"sourceType": "github", "skillFolderHash": "abc"},
        }})
        outcome = self.run_update(lock_content=lock, update_report="current")
        self.assertNotEqual(outcome["result"].returncode, 0)
        self.assertIn("missing-hash", outcome["result"].stderr)
        self.assertIn("missing-path", outcome["result"].stderr)
        self.assertNotIn("All global skills are up to date", outcome["result"].stdout)
        self.assertEqual(outcome["trace"], ["update", "--global", "--yes"])
        self.assertEqual(outcome["saved_lock"], lock)

    def test_supported_non_git_sources_are_checkable(self):
        lock = json.dumps({"version": 3, "skills": {
            "well-known": {"sourceType": "well-known", "sourceBaseUrl": "https://example.invalid",
                           "wellKnownDigest": "abc"},
            "download": {"sourceType": "download", "sourceUrl": "https://example.invalid/skill"},
        }})
        outcome = self.run_update(lock_content=lock, update_report="current")
        self.assertEqual(outcome["result"].returncode, 0, outcome["result"].stderr)
        self.assertIn("All global skills are up to date", outcome["result"].stdout)

    def test_invalid_or_obsolete_lock_stops_before_updating(self):
        for lock in (
            "not json",
            json.dumps({"version": 2, "skills": {}}),
            json.dumps({"version": 3, "skills": []}),
            json.dumps({"version": 3, "skills": {"invalid": None}}),
        ):
            with self.subTest(lock=lock):
                outcome = self.run_update(lock_content=lock)
                self.assertNotEqual(outcome["result"].returncode, 0)
                self.assertIsNone(outcome["trace"])
                self.assertEqual(outcome["current"], "canonical edit")
                self.assertEqual(outcome["saved_lock"], lock)

    def test_reported_failures_override_a_successful_updater_exit(self):
        for report, message in (
            ("source", "Failed to check skills from"),
            ("target", "claude-code: permission denied"),
            ("warning", "Warning:"),
            ("uncheckable", "cannot be checked automatically"),
        ):
            with self.subTest(report=report):
                outcome = self.run_update(update_report=report)
                self.assertNotEqual(outcome["result"].returncode, 0)
                self.assertIn(message, outcome["result"].stdout + outcome["result"].stderr)
                self.assertIn("reported failure", outcome["result"].stderr)
                self.assertNotIn("All global skills are up to date", outcome["result"].stdout)

    def test_up_to_date_message_is_kept_when_all_checks_succeed(self):
        outcome = self.run_update(update_report="current")
        self.assertEqual(outcome["result"].returncode, 0, outcome["result"].stderr)
        self.assertIn("All global skills are up to date", outcome["result"].stdout)


if __name__ == "__main__":
    unittest.main()
