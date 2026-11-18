#!/usr/bin/env python3
"""Check update ownership in the workstation Topgrade configuration."""

import json
import os
from pathlib import Path
import shlex
import subprocess
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
in {
  disabled = settings.misc.disable;
  guixSystem = settings.pre_commands."1. Deploy Guix System";
  hasPluginUpdater = settings.commands ? "Hyprland plugins";
  hasGitHubSkillsUpdater = settings.commands ? "GitHub CLI managed skills";
  hasClaudePluginUpdater = settings.commands ? "Claude Code plugins";
  autoEmptyTrash = settings.post_commands ? "Empty Trash";
  autoPrunePodman = settings.post_commands ? "Prune Podman images";
  autoCollectNix = settings.post_commands ? "Garbage collect Nix";
  flatpakCleanup = settings.post_commands."Remove unused Flatpak runtimes";
  distrobox = settings.commands."Distrobox (arch)";
}
"""


class TopgradeConfigTest(unittest.TestCase):
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

    def test_tailscale_updates_through_guix_system(self):
        self.assertIn("tailscale", self.settings["disabled"])
        self.assertIn(
            "just guix-pull-system && just deploy-mahakala-system",
            self.settings["guixSystem"],
        )

    def test_plugin_updater_replaces_the_unconditional_step(self):
        self.assertIn("hyprpm", self.settings["disabled"])
        self.assertTrue(self.settings["hasPluginUpdater"])

    def test_github_skills_updater_replaces_the_unscoped_step(self):
        self.assertIn("github_cli_skills", self.settings["disabled"])
        self.assertTrue(self.settings["hasGitHubSkillsUpdater"])

    def test_claude_plugin_updater_replaces_the_hooked_step(self):
        self.assertIn("claude_code_plugins", self.settings["disabled"])
        self.assertTrue(self.settings["hasClaudePluginUpdater"])

    def test_updates_do_not_automatically_purge_trash(self):
        self.assertFalse(self.settings["autoEmptyTrash"])

    def test_updates_do_not_prune_other_workloads_images(self):
        self.assertFalse(self.settings["autoPrunePodman"])

    def test_updates_do_not_collect_the_shared_nix_store(self):
        self.assertFalse(self.settings["autoCollectNix"])

    def test_flatpak_cleanup_is_limited_to_the_user_installation(self):
        self.assertEqual(
            shlex.split(self.settings["flatpakCleanup"]),
            ["flatpak", "uninstall", "--user", "--unused", "-y"],
        )

    def test_distrobox_hooks_are_adapted_before_the_upgrade(self):
        hooks, upgrade = self.settings["distrobox"].split(" && ")
        self.assertRegex(hooks, r"^distrobox enter arch -- sudo bash -s < /nix/store/\S+-topgrade-arch-distrobox-hooks\.sh$")
        self.assertEqual(upgrade, "distrobox-upgrade arch")


if __name__ == "__main__":
    unittest.main()
