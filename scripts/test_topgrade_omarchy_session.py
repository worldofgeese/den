#!/usr/bin/env python3
"""Verify Omarchy activation on a desktop without a systemd user manager."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
EXPRESSION = """
let
  module = import (builtins.toPath (builtins.getEnv "OMARCHY_MODULE")) {
    den = {};
    inputs = { nixarchy = {}; };
  };
  package = {
    __toString = _: builtins.getEnv "FAKE_PACKAGE";
    passthru.runtimeDeps = [];
  };
  result = module.den.aspects.omarchy.homeManager {
    pkgs = {};
    config.programs.nixarchy.package = package;
    lib = {
      mkForce = value: value;
      hm.dag.entryAfter = deps: data: { inherit data; after = deps; };
      makeBinPath = _: "/usr/bin:/bin";
    };
  };
in result.home.activation.nixarchySyncSession.data
  or "systemctl --user is-active --quiet graphical-session.target"
"""

HELPER = """\
#!/usr/bin/env bash
printf '%s\\n' "$*" >>"$TRACE"
if [[ ${FAIL_SYNC:-0} == 1 ]]; then echo 'session sync failed' >&2; exit 1; fi
"""


class OmarchySessionTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="omarchy-session-test-")
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        executable = root / "bin/nixarchy-shell-session"
        executable.parent.mkdir()
        executable.write_text(HELPER)
        executable.chmod(0o755)
        self.trace = root / "trace"
        self.env = os.environ | {
            "OMARCHY_MODULE": str(ROOT / "modules/omarchy.nix"),
            "FAKE_PACKAGE": str(root),
            "TRACE": str(self.trace),
        }
        self.env.pop("WAYLAND_DISPLAY", None)
        self.script = subprocess.run(
            ["nix", "eval", "--extra-experimental-features", "nix-command",
             "--impure", "--raw", "--expr", EXPRESSION],
            check=True,
            capture_output=True,
            text=True,
            env=self.env,
        ).stdout

    def run_activation(self, **variables):
        return subprocess.run(
            ["bash", "-c", 'set -e\nrun() { "$@"; }\n' + self.script],
            capture_output=True,
            text=True,
            env=self.env | variables,
        )

    def calls(self):
        return self.trace.read_text().splitlines() if self.trace.exists() else []

    def test_graphical_session_is_synchronized(self):
        result = self.run_activation(WAYLAND_DISPLAY="wayland-test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), ["sync --if-running"])

    def test_non_graphical_activation_does_not_probe_user_systemd(self):
        result = self.run_activation()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(self.calls(), [])

    def test_synchronization_failure_is_visible(self):
        result = self.run_activation(WAYLAND_DISPLAY="wayland-test", FAIL_SYNC="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("session sync failed", result.stderr)
        self.assertEqual(self.calls(), ["sync --if-running"])


class OmarchySessionGuardTest(unittest.TestCase):
    def run_guard(self, tree):
        guard = ROOT / "scripts/omarchy-guix/session-sync-guard.sh"
        return subprocess.run(
            ["bash", str(guard), str(tree)],
            capture_output=True,
            text=True,
        )

    def test_mutable_profile_defers_sync_even_when_it_points_into_the_store(self):
        store_tree = next(path for path in Path("/nix/store").iterdir()
                          if path.is_dir() and not path.is_symlink())
        with tempfile.TemporaryDirectory(prefix="omarchy-guard-") as work:
            mutable = Path(work) / "home-path"
            mutable.symlink_to(store_tree, target_is_directory=True)
            result = self.run_guard(mutable)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("synchronization deferred", result.stderr)

    def test_immutable_store_tree_permits_sync(self):
        store_tree = next(path for path in Path("/nix/store").iterdir()
                          if path.is_dir() and not path.is_symlink())
        result = self.run_guard(store_tree)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

    def test_unresolvable_store_tree_is_an_error(self):
        result = self.run_guard("/nix/store/omarchy-session-guard-no-such-tree")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot resolve", result.stderr)


class OmarchyLauncherTest(unittest.TestCase):
    def test_missing_hyprland_is_reported_in_the_session_log(self):
        with tempfile.TemporaryDirectory(prefix="omarchy-launcher-") as work:
            root = Path(work)
            home = root / "home"
            profile = home / ".local/state/nix/profiles/home-manager/home-path"
            (profile / "share/omarchy").mkdir(parents=True)
            result = subprocess.run(
                ["sh", str(ROOT / "guix/omarchy-session.sh")],
                capture_output=True,
                text=True,
                env=os.environ | {"HOME": str(home)},
            )
            log = home / ".local/state/omarchy-session.log"
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("FATAL: no Hyprland", log.read_text())

    def test_session_keeps_its_generation_when_the_profile_changes(self):
        with tempfile.TemporaryDirectory(prefix="omarchy-launcher-") as work:
            root = Path(work)
            home = root / "home"
            profile = home / ".local/state/nix/profiles/home-manager/home-path"
            profile.parent.mkdir(parents=True)
            generations = [root / "old-generation", root / "new-generation"]
            for generation in generations:
                (generation / "bin").mkdir(parents=True)
                config = generation / "share/omarchy/config/hypr/hyprland.lua"
                config.parent.mkdir(parents=True)
                config.write_text(generation.name)
                (generation / "share/omarchy/bin").mkdir()
                hyprland = generation / "bin/Hyprland"
                hyprland.write_text("#!/bin/sh\nexit 0\n")
                hyprland.chmod(0o755)
            launcher = generations[0] / "bin/start-hyprland"
            launcher.write_text(
                "#!/bin/sh\n"
                'ln -sfn "$NEXT_PROFILE" "$PROFILE_LINK"\n'
                'printf "tree=%s\\n" "$OMARCHY_PATH" >"$TRACE"\n'
                'printf "path=%s\\n" "$PATH" >>"$TRACE"\n'
                'printf "arg=%s\\n" "$@" >>"$TRACE"\n'
                'readlink -f "$OMARCHY_PATH/config/hypr/hyprland.lua" >>"$TRACE"\n'
            )
            launcher.chmod(0o755)
            profile.symlink_to(generations[0], target_is_directory=True)
            trace = root / "trace"
            env = {
                "HOME": str(home),
                "PATH": os.environ["PATH"],
                "PROFILE_LINK": str(profile),
                "NEXT_PROFILE": str(generations[1]),
                "TRACE": str(trace),
                "XDG_RUNTIME_DIR": str(root / "runtime"),
            }
            result = subprocess.run(
                ["sh", str(ROOT / "guix/omarchy-session.sh")],
                capture_output=True,
                text=True,
                env=env,
            )
            log = home / ".local/state/omarchy-session.log"
            self.assertEqual(result.returncode, 0, log.read_text() if log.exists() else result.stderr)
            output = trace.read_text()
            self.assertIn(f"tree={generations[0] / 'share/omarchy'}", output)
            self.assertIn(f"arg={generations[0] / 'bin/Hyprland'}", output)
            self.assertIn(
                f"path=/run/privileged/bin:{generations[0] / 'bin'}:"
                f"{generations[0] / 'share/omarchy/bin'}:{profile / 'bin'}:",
                output,
            )
            self.assertIn(str(generations[0] / "share/omarchy/config/hypr/hyprland.lua"), output)
            self.assertEqual(profile.resolve(), generations[1])


if __name__ == "__main__":
    unittest.main()
