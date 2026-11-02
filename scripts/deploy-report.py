#!/usr/bin/env python3
"""Report what each den deploy target runs, and keep one GitHub issue per failing step.

Plan step P8 (docs/plans/2026-10-30-001-dagger-ci-autonomous-merge-plan.md).
A launchd agent on M-02877 runs this script each day. For each host it reads
the deployed den commit and the nixpkgs revision. paphos and oracle fetch
nixos-unstable at upgrade time, so the revision that runs is not the one in
flake.lock. Each failing step gets one open issue with the label
`deploy-report`. A later run that sees the step pass closes that issue with its
evidence. An unreachable host closes nothing, because its other steps are
unknown.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any

REPO = "worldofgeese/den"
LABEL = "deploy-report"
TITLE = re.compile(r"^deploy: (?P<host>[A-Za-z0-9-]+): (?P<step>[a-z-]+)$")
BEHIND_HOURS = 36
NIXPKGS_DAYS = 14
REBOOT_DAYS = 2

# The hosts that den deploys and that this report can observe. mahakala runs
# Guix System and a Home Manager profile, and pixel-fold runs nix-on-droid:
# neither records the den commit, so the report cannot judge them yet.
HOSTS = {
    "paphos": {"kind": "nixos", "ssh": "paphos"},
    "oracle": {"kind": "nixos", "ssh": "oracle"},
    "M-02877": {"kind": "darwin", "ssh": None},
}

# One remote call per NixOS host. It prints one JSON object and no secrets.
NIXOS_PROBE = r"""
set -u
sw=/run/current-system/sw/bin
rev=$("$sw/sed" -n 1p /etc/den-revision 2>/dev/null | "$sw/tr" -cd '0-9a-f')
nar=$("$sw/sed" -n 2p /etc/den-revision 2>/dev/null | "$sw/tr" -cd 'A-Za-z0-9+/=-')
modified=$("$sw/sed" -n 3p /etc/den-revision 2>/dev/null | "$sw/tr" -cd '0-9')
build=$("$sw/sed" -n 's/^BUILD_ID="\{0,1\}\([0-9A-Za-z.]*\)"\{0,1\}$/\1/p' /etc/os-release)
failed=false; "$sw/systemctl" is-failed --quiet nixos-upgrade.service && failed=true
booted=$("$sw/readlink" -f /run/booted-system/kernel)
current=$("$sw/readlink" -f /run/current-system/kernel)
switched=$("$sw/stat" -c %Y /run/current-system)
pending=false; [ "$booted" = "$current" ] || pending=true
printf '{"den_revision":"%s","nar_hash":"%s","last_modified":"%s","build_id":"%s","upgrade_failed":%s,"kernel_pending":%s,"switched_epoch":%s}\n' \
  "$rev" "$nar" "$modified" "$build" "$failed" "$pending" "$switched"
"""


@dataclass
class Observation:
    host: str
    reachable: bool
    den_revision: str | None = None
    nar_hash: str | None = None
    last_modified: int | None = None
    nixpkgs_revision: str | None = None
    nixos_version: str | None = None
    upgrade_failed: bool = False
    kernel_pending: bool = False
    switched_epoch: int | None = None
    behind_by: int | None = None
    oldest_missing_epoch: int | None = None
    error: str | None = None
    failures: dict[str, str] = field(default_factory=dict)


def run(args: list[str], timeout: int = 60, stdin: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, input=stdin, text=True, capture_output=True, timeout=timeout)


def gh_json(args: list[str]) -> Any:
    result = run(["gh", *args])
    if result.returncode:
        raise RuntimeError(f"gh {' '.join(args[:2])} failed")
    return json.loads(result.stdout or "null")


def observe_nixos(host: str, ssh: str | None) -> Observation:
    if ssh is None:
        return Observation(host, False, error="no ssh destination")
    try:
        result = run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=10",
                      ssh, "bash", "-s"], stdin=NIXOS_PROBE, timeout=60)
    except subprocess.TimeoutExpired:
        return Observation(host, False, error="ssh timed out")
    if result.returncode:
        return Observation(host, False, error=f"ssh exit {result.returncode}")
    try:
        data = json.loads(result.stdout.strip().splitlines()[-1])
        build = str(data["build_id"])
        version = re.fullmatch(r"(\d+\.\d+)\.(\d{8})\.([0-9a-f]{7,40})", build)
        return Observation(host, True, den_revision=data["den_revision"] or None,
                           nar_hash=data.get("nar_hash") or None,
                           last_modified=int(data.get("last_modified") or 0) or None,
                           nixpkgs_revision=version.group(3) if version else None,
                           nixos_version=build or None,
                           upgrade_failed=data["upgrade_failed"] is True,
                           kernel_pending=data["kernel_pending"] is True,
                           switched_epoch=int(data["switched_epoch"]))
    except (IndexError, KeyError, TypeError, ValueError):
        return Observation(host, False, error="the probe returned an unexpected answer")


def observe_darwin(host: str) -> Observation:
    try:
        lines = Path("/etc/den-revision").read_text().splitlines() + ["", "", ""]
    except OSError:
        lines = ["", "", ""]
    revision = lines[0].strip() or None
    nar_hash = lines[1].strip() or None
    last_modified = int(lines[2].strip()) if lines[2].strip().isdigit() else None
    exe = shutil.which("darwin-version") or "/run/current-system/sw/bin/darwin-version"
    try:
        data = json.loads(run([exe, "--json"]).stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        data = {}
    return Observation(host, True, den_revision=revision, nar_hash=nar_hash, last_modified=last_modified,
                       nixpkgs_revision=data.get("nixpkgsRevision"))


def flake_nar_hash(revision: str) -> str | None:
    result = run(["nix", "flake", "metadata", "--json", f"github:{REPO}/{revision}"], timeout=300)
    if result.returncode:
        return None
    return json.loads(result.stdout).get("locked", {}).get("narHash")


def resolve_revision(observation: Observation, nar_of=flake_nar_hash) -> None:
    """Find the main commit of a build without self.rev, by commit time and narHash.

    `nixos-upgrade --override-input nixpkgs ...` drops self.rev but keeps
    narHash and lastModified. lastModified of a GitHub flake is the commit time.
    """
    if observation.den_revision or not (observation.nar_hash and observation.last_modified):
        return
    stamp = datetime.fromtimestamp(observation.last_modified, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        commits = gh_json(["api", f"repos/{REPO}/commits?sha=main&since={stamp}&until={stamp}&per_page=20"]) or []
    except RuntimeError:
        return
    for commit in commits:
        sha = commit.get("sha", "")
        if re.fullmatch(r"[0-9a-f]{40}", sha) and nar_of(sha) == observation.nar_hash:
            observation.den_revision = sha
            return


def compare_with_main(observation: Observation) -> None:
    """Count the main commits that the deployed commit lacks, and the age of the oldest."""
    revision = observation.den_revision
    if not revision or not re.fullmatch(r"[0-9a-f]{40}", revision):
        return
    try:
        data = gh_json(["api", f"repos/{REPO}/compare/{revision}...main"])
    except RuntimeError:
        observation.den_revision = None  # unknown to GitHub, for example an unpushed commit
        return
    observation.behind_by = int(data.get("ahead_by", 0))
    dates = [c["commit"]["committer"]["date"] for c in data.get("commits", [])]
    if dates:
        oldest = min(datetime.fromisoformat(d.replace("Z", "+00:00")) for d in dates)
        observation.oldest_missing_epoch = int(oldest.timestamp())


def judge(observation: Observation, now: datetime) -> dict[str, str]:
    """Return the failing steps of one observation, each with its evidence."""
    failures: dict[str, str] = {}
    if not observation.reachable:
        failures["unreachable"] = observation.error or "no answer"
        return failures
    if observation.upgrade_failed:
        failures["upgrade-failed"] = "nixos-upgrade.service is in the failed state"
    if not observation.den_revision:
        failures["den-revision-unknown"] = "the system records no den commit that GitHub knows"
    elif observation.behind_by and observation.oldest_missing_epoch:
        hours = (now.timestamp() - observation.oldest_missing_epoch) / 3600
        if hours > BEHIND_HOURS:
            failures["den-behind-main"] = (f"{observation.behind_by} commits of main are missing; "
                                           f"the oldest is {hours:.0f} h old")
    if observation.nixos_version:
        match = re.search(r"\.(\d{8})\.", observation.nixos_version)
        if match:
            built = datetime.strptime(match.group(1), "%Y%m%d").replace(tzinfo=timezone.utc)
            days = (now - built).days
            if days >= NIXPKGS_DAYS:
                failures["nixpkgs-stale"] = f"nixpkgs {observation.nixos_version} is {days} days old"
    if observation.kernel_pending and observation.switched_epoch:
        days = (now.timestamp() - observation.switched_epoch) / 86400
        if days >= REBOOT_DAYS:
            failures["reboot-pending"] = f"a new kernel has waited {days:.0f} days for a reboot"
    return failures


def plan_issue_changes(observations: list[Observation], open_issues: list[dict[str, Any]]) -> tuple[list[tuple[str, str, str]], list[tuple[int, str]]]:
    """Return (issues to open, issues to close) without side effects."""
    open_titles: dict[tuple[str, str], int] = {}
    for issue in open_issues:
        match = TITLE.match(issue["title"])
        if match:
            open_titles[(match["host"], match["step"])] = issue["number"]
    to_open = []
    to_close = []
    for o in observations:
        for step, evidence in o.failures.items():
            if (o.host, step) not in open_titles:
                to_open.append((o.host, step, evidence))
        if not o.reachable:
            continue  # its other steps are unknown, so nothing closes
        for (host, step), number in open_titles.items():
            if host == o.host and step not in o.failures:
                to_close.append((number, f"{host} passes `{step}` again: {summary(o)}"))
    return to_open, to_close


def summary(o: Observation) -> str:
    if not o.reachable:
        return f"unreachable ({o.error})"
    den = o.den_revision[:12] if o.den_revision else "unknown"
    behind = "" if o.behind_by is None else f", {o.behind_by} behind main"
    return f"den {den}{behind}, nixpkgs {(o.nixpkgs_revision or 'unknown')[:12]}"


def body(host: str, step: str, evidence: str, o: Observation, now: datetime) -> str:
    return (f"The deploy report on M-02877 found a failing step on `{host}` at {now.isoformat(timespec='seconds')}.\n\n"
            f"- Step: `{step}`\n- Evidence: {evidence}\n- Host state: {summary(o)}\n\n"
            "The next report that sees this step pass closes this issue. A fix PR can also close it.\n"
            "The issue shepherd (plan P7) must not close it. See scripts/deploy-report.py.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Print the planned issue changes only")
    args = parser.parse_args()
    now = datetime.now(timezone.utc)
    observations = []
    for host, spec in HOSTS.items():
        o = observe_nixos(host, spec["ssh"]) if spec["kind"] == "nixos" else observe_darwin(host)
        if o.reachable:
            resolve_revision(o)
            compare_with_main(o)
        o.failures = judge(o, now)
        observations.append(o)
        print(f"{host}: {summary(o)}; failing: {', '.join(o.failures) or 'none'}")
    issues = gh_json(["issue", "list", "-R", REPO, "--label", LABEL, "--state", "open",
                      "--limit", "200", "--json", "number,title"]) or []
    to_open, to_close = plan_issue_changes(observations, issues)
    for host, step, evidence in to_open:
        print(f"open: deploy: {host}: {step} ({evidence})")
    for number, note in to_close:
        print(f"close: #{number} ({note})")
    if args.dry_run:
        return 0
    if to_open:
        run(["gh", "label", "create", LABEL, "-R", REPO, "--color", "B60205",
             "--description", "Opened and closed by scripts/deploy-report.py"])
    by_host = {o.host: o for o in observations}
    status = 0
    for host, step, evidence in to_open:
        result = run(["gh", "issue", "create", "-R", REPO, "--label", LABEL, "--title", f"deploy: {host}: {step}",
                      "--body", body(host, step, evidence, by_host[host], now)])
        status |= result.returncode
    for number, note in to_close:
        result = run(["gh", "issue", "close", str(number), "-R", REPO, "--comment", note])
        status |= result.returncode
    return 1 if status else 0


if __name__ == "__main__":
    sys.exit(main())
