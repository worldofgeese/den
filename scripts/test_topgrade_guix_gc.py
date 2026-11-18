#!/usr/bin/env python3
"""Exercise Topgrade's Guix cleanup without touching real generations."""

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
in
  (workstation.den.aspects.workstation.homeManager { config = {}; pkgs = {}; lib = {}; })
    .programs.topgrade.settings.post_commands."Garbage collect Guix"
"""

GUIX_STUB = """\
#!/usr/bin/env bash
if [[ $1 == repl ]]; then
  scope=${*: -1}
  printf 'select %s\\n' "$scope" >>"$TRACE"
  if [[ ${BAD_SELECTION:-} == "$scope" ]]; then
    echo 'not-a-generation'
  elif [[ ${FAIL_SELECTION:-} == "$scope" ]]; then
    echo 'selection failed' >&2
    exit 1
  elif [[ ${NO_MATCHES:-0} != 1 && !( ${OLD_CURRENT:-0} == 1 && $scope == package ) ]]; then
    printf '4,5'
  fi
  exit 0
fi
printf '%s\\n' "$*" >>"$TRACE"
case "$*" in
  'package --delete-generations=4,5'|'home delete-generations 4,5'|\
'system delete-generations 4,5'|'gc') ;;
  *) echo "unexpected command: $*" >&2; exit 2 ;;
esac
if [[ ${OLD_CURRENT:-0} == 1 && "$1" == package ]]; then
  printf 'guix package: warning: not removing generation 17, which is current\\n' >&2
  printf 'guix package: error: no matching generation\\n' >&2
  exit 1
fi
if [[ ${FAIL_SCOPE:-} == "$1" ]]; then
  printf 'guix %s: error: no matching generation\\nfatal: store I/O error\\n' "$1" >&2
  exit 1
fi
"""


class GuixCleanupTest(unittest.TestCase):
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

    def run_cleanup(self, **variables):
        with tempfile.TemporaryDirectory(prefix="topgrade-guix-gc-test-") as work:
            root = Path(work)
            for name, body in {
                "guix": GUIX_STUB,
                "sudo": "#!/usr/bin/env bash\nexec \"$@\"\n",
            }.items():
                executable = root / name
                executable.write_text(body)
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

    def test_empty_generations_still_run_gc(self):
        result, calls = self.run_cleanup(NO_MATCHES="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            "select package",
            "select home",
            "select system",
            "gc",
        ])
        self.assertNotIn("error:", result.stdout + result.stderr)

    def test_only_selected_generations_are_deleted(self):
        result, calls = self.run_cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            "select package",
            "package --delete-generations=4,5",
            "select home",
            "home delete-generations 4,5",
            "select system",
            "system delete-generations 4,5",
            "gc",
        ])

    def test_system_failure_stops_garbage_collection(self):
        result, calls = self.run_cleanup(FAIL_SCOPE="system")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fatal: store I/O error", result.stderr)
        self.assertNotIn("gc", calls)

    def test_old_current_generation_is_not_deleted(self):
        result, calls = self.run_cleanup(OLD_CURRENT="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("warning:", result.stdout + result.stderr)
        self.assertNotIn("package --delete-generations=4,5", calls)

    def test_invalid_selection_stops_garbage_collection(self):
        result, calls = self.run_cleanup(BAD_SELECTION="system")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid system generation selection", result.stderr)
        self.assertNotIn("gc", calls)

    def test_selection_failure_stops_garbage_collection(self):
        result, calls = self.run_cleanup(FAIL_SELECTION="home")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("selection failed", result.stderr)
        self.assertNotIn("gc", calls)

    @unittest.skipUnless(shutil.which("guix"), "Guix is not installed")
    def test_selector_excludes_current_generation(self):
        with tempfile.TemporaryDirectory(prefix="guix-generation-selector-") as work:
            root = Path(work)
            profiles = root / "profiles/per-user/testuser"
            profiles.mkdir(parents=True)
            for number in (1, 2, 3):
                target = root / f"generation-{number}"
                target.mkdir()
                (profiles / f"guix-profile-{number}-link").symlink_to(target)
            (profiles / "guix-profile").symlink_to("guix-profile-2-link")
            env = os.environ | {
                "GUIX_STATE_DIRECTORY": work,
                "USER": "testuser",
                "SELECTOR": str(ROOT / "scripts/topgrade-guix-generations.scm"),
            }
            program = """
              (use-modules (guix ui) (srfi srfi-19))
              (let* ((module (resolve-module '(guix ui)))
                     (now (module-ref module 'current-time))
                     (generation-time (module-ref module 'generation-time)))
                (module-set! module 'current-time
                  (lambda args
                    (add-duration (apply now args)
                                  (make-time time-duration 0 (* 16 24 60 60)))))
                (module-set! module 'generation-time
                  (lambda (profile number)
                    (if (= number 3)
                        (add-duration (now)
                                      (make-time time-duration 0 (* 15 24 60 60)))
                        (generation-time profile number)))))
              (primitive-load (getenv "SELECTOR"))
            """
            result = subprocess.run(
                ["guix", "repl", "-q", "--", "/dev/stdin", "package"],
                input=program,
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "1")


if __name__ == "__main__":
    unittest.main()
