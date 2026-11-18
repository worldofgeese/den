#!/usr/bin/env python3
"""Run the Arch Distrobox hook adaptation against a throwaway root."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/topgrade-arch-distrobox-hooks.sh"
MASKED = [
    "10-openssh-mark-sshd-for-restart", "25-systemd-sysctl",
    "30-systemd-daemon-reload-system", "30-systemd-daemon-reload-user",
    "35-systemd-enqueue-marked", "35-systemd-udev-reload",
    "70-openssh-restart-sshd", "dbus-reload",
]


class ArchDistroboxHooksTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.packaged = self.root / "usr/share/libalpm/hooks"
        self.packaged.mkdir(parents=True)
        for hook in MASKED:
            (self.packaged / f"{hook}.hook").write_text("")
        (self.root / "etc/ssl/private").mkdir(parents=True, mode=0o755)

    def run_script(self):
        return subprocess.run(["bash", str(SCRIPT), str(self.root)],
                              capture_output=True, text=True)

    def test_masks_hooks_and_is_idempotent(self):
        for _ in range(2):
            result = self.run_script()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
        hooks = self.root / "etc/pacman.d/hooks"
        for hook in MASKED:
            self.assertEqual(os.readlink(hooks / f"{hook}.hook"), "/dev/null")
        tmpfiles = (hooks / "21-systemd-tmpfiles.hook").read_text()
        self.assertIn("--exclude-prefix=/dev --exclude-prefix=/tmp --exclude-prefix=/run", tmpfiles)
        self.assertEqual((self.root / "etc/ssl/private").stat().st_mode & 0o777, 0o700)

    def test_warns_when_a_masked_hook_is_no_longer_shipped(self):
        (self.packaged / "dbus-reload.hook").unlink()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dbus-reload.hook", result.stderr)


if __name__ == "__main__":
    unittest.main()
