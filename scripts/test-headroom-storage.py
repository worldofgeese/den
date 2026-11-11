#!/usr/bin/env python3
"""Exercise the rendered Headroom launch script without touching containers."""

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ATTRIBUTE = (
    ".#darwinConfigurations.M-02877.config.launchd.user.agents."
    "headroom-proxy.serviceConfig.ProgramArguments"
)


def main():
    jq = shutil.which("jq")
    if not jq:
        raise RuntimeError("jq is required for the Headroom storage regression")
    result = subprocess.run(
        ["nix", "eval", "--json", ATTRIBUTE],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    arguments = json.loads(result.stdout)
    if arguments[:2] != ["/bin/sh", "-c"] or len(arguments) != 3:
        raise AssertionError("Unexpected Headroom launch interface")

    with tempfile.TemporaryDirectory(prefix="headroom-storage-test-") as temporary:
        directory = Path(temporary)
        mock = directory / "container"
        mock.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, sys\n"
            "args = sys.argv[1:]\n"
            "with open(os.environ['MOCK_CALLS'], 'a') as out:\n"
            "    out.write(json.dumps(args) + '\\n')\n"
            "if args[:2] == ['volume', 'list']:\n"
            "    print(os.environ['MOCK_VOLUMES'])\n"
            "    sys.exit(int(os.environ.get('MOCK_LIST_EXIT', '0')))\n"
            "if args[:2] == ['image', 'pull']:\n"
            "    sys.exit(int(os.environ.get('MOCK_PULL_EXIT', '0')))\n"
            "if args[:2] == ['image', 'inspect']:\n"
            "    sys.exit(int(os.environ.get('MOCK_INSPECT_EXIT', '0')))\n"
            "if args and args[0] in ['system', 'network', 'stop', 'rm', 'run']:\n"
            "    sys.exit(0)\n"
            "sys.exit(99)\n"
        )
        mock.chmod(0o755)
        script, replaced = re.subn(
            r"(?m)^\s*C=/opt/homebrew/bin/container\s*$",
            "C=" + shlex.quote(str(mock)),
            arguments[2],
        )
        if replaced != 1 or "/opt/homebrew/bin/container" in script:
            raise AssertionError("The real container CLI must never run in this test")
        script, replaced = re.subn(
            r"(?m)^\s*JQ=/nix/store/[^\n]+/bin/jq\s*$",
            "JQ=" + shlex.quote(jq),
            script,
        )
        if replaced != 1:
            raise AssertionError("The rendered jq dependency was not found")
        executable = directory / "launch.sh"
        executable.write_text(script)
        calls_file = directory / "calls.jsonl"
        cases = [
            ("fresh host", [], True, {}),
            ("legacy needs recovery", [{"id": "headroom-data"}], False, {}),
            ("restored workspace", [{"id": "headroom-workspace"}], True, {}),
            (
                "old volume retained",
                [{"id": "headroom-data"}, {"id": "headroom-workspace"}],
                True,
                {},
            ),
            ("bad inventory shape", {}, False, {}),
            ("bad inventory entry", [{"id": 7}], False, {}),
            ("unparseable inventory", [], False, {"MOCK_VOLUMES": "{"}),
            ("empty inventory output", [], False, {"MOCK_VOLUMES": ""}),
            ("backend unavailable", [], False, {"MOCK_LIST_EXIT": "1"}),
            ("cached image fallback", [], True, {"MOCK_PULL_EXIT": "1"}),
            (
                "image unavailable",
                [],
                False,
                {"MOCK_PULL_EXIT": "1", "MOCK_INSPECT_EXIT": "1"},
            ),
        ]
        for name, volumes, allowed, overrides in cases:
            calls_file.write_text("")
            environment = os.environ.copy()
            environment.update(
                MOCK_CALLS=str(calls_file),
                MOCK_VOLUMES=json.dumps(volumes),
                MOCK_LIST_EXIT="0",
                MOCK_PULL_EXIT="0",
                MOCK_INSPECT_EXIT="0",
            )
            environment.update(overrides)
            completed = subprocess.run(
                ["/bin/sh", str(executable)],
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
            )
            calls = [json.loads(line) for line in calls_file.read_text().splitlines()]
            destructive = [args for args in calls if args[0] in ("stop", "rm", "run")]
            if allowed:
                assert completed.returncode == 0, (name, completed.stderr)
                launched = [args for args in calls if args[0] == "run"]
                assert len(launched) == 1, name
                assert "headroom-workspace:/data" in launched[0], name
                pull = next(args for args in calls if args[:2] == ["image", "pull"])
                assert calls.index(pull) < calls.index(destructive[0]), name
            else:
                assert completed.returncode != 0, name
                assert not destructive, (name, destructive)
            print("PASS:", name)


if __name__ == "__main__":
    main()
