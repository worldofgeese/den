#!/usr/bin/env python3
"""Exercise the checkout sync that runs before Topgrade's deploy steps."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/topgrade-sync-checkout.sh"
EXPRESSION = """
let
  workstation = import (builtins.toPath (builtins.getEnv "WORKSTATION_MODULE")) {
    den = {};
    inputs = {};
  };
  settings = (workstation.den.aspects.workstation.homeManager { config = {}; pkgs = {}; lib = {}; })
    .programs.topgrade.settings;
in builtins.attrNames settings.pre_commands
"""
# A pre-commit hook exports GIT_DIR and friends; they must not reach the
# throwaway repositories.
ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")} | {
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
    "GIT_CONFIG_GLOBAL": "/dev/null",
}


def git(cwd, *args):
    return subprocess.run(["git", *args], cwd=cwd, env=ENV, check=True,
                          capture_output=True, text=True).stdout.strip()


class SyncCheckoutTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        self.upstream = base / "upstream"
        self.checkout = base / "checkout"
        git(base, "init", "-q", "-b", "main", str(self.upstream))
        (self.upstream / "flake.lock").write_text("lock 1\n")
        (self.upstream / "config").write_text("config 1\n")
        git(self.upstream, "add", ".")
        git(self.upstream, "commit", "-q", "-m", "one")
        git(base, "clone", "-q", str(self.upstream), str(self.checkout))
        (self.upstream / "flake.lock").write_text("lock 2\n")
        (self.upstream / "config").write_text("config 2\n")
        git(self.upstream, "commit", "-q", "-am", "two")
        self.upstream_head = git(self.upstream, "rev-parse", "HEAD")

    def sync(self):
        return subprocess.run(["bash", str(SCRIPT), str(self.checkout)], env=ENV,
                              capture_output=True, text=True)

    def test_fast_forwards_over_the_previous_runs_lock_bumps(self):
        (self.checkout / "flake.lock").write_text("bumped by just update\n")
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), self.upstream_head)
        self.assertEqual((self.checkout / "flake.lock").read_text(), "lock 2\n")

    def test_refuses_a_branch_other_than_main(self):
        git(self.checkout, "switch", "-q", "-c", "feature")
        before = git(self.checkout, "rev-parse", "HEAD")
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not main", result.stderr)
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), before)

    def test_keeps_other_local_changes_and_fails(self):
        (self.checkout / "config").write_text("local edit\n")
        before = git(self.checkout, "rev-parse", "HEAD")
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), before)
        self.assertEqual((self.checkout / "config").read_text(), "local edit\n")

    def test_sync_runs_before_every_deploy_step(self):
        env = os.environ | {"WORKSTATION_MODULE": str(ROOT / "modules/workstation.nix")}
        names = json.loads(subprocess.run(
            ["nix", "eval", "--extra-experimental-features", "nix-command",
             "--impure", "--json", "--expr", EXPRESSION],
            check=True, capture_output=True, text=True, env=env,
        ).stdout)
        self.assertEqual(sorted(names)[0], "0. Sync den checkout")


if __name__ == "__main__":
    unittest.main()
