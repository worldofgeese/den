from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("deploy_report", Path(__file__).with_name("deploy-report.py"))
assert spec and spec.loader
report = importlib.util.module_from_spec(spec)
import sys
sys.modules[spec.name] = report
spec.loader.exec_module(report)

NOW = datetime(2026, 11, 2, 8, 0, tzinfo=timezone.utc)
REV = "a" * 40


def healthy(host: str = "paphos") -> "report.Observation":
    return report.Observation(host, True, den_revision=REV, nixpkgs_revision="b" * 40,
                              nixos_version="26.11.20261030.1c89083", switched_epoch=int(NOW.timestamp()),
                              behind_by=0)


class JudgeTests(unittest.TestCase):
    def test_a_current_host_passes(self) -> None:
        self.assertEqual(report.judge(healthy(), NOW), {})

    def test_unreachable_reports_only_that(self) -> None:
        o = report.Observation("oracle", False, error="ssh exit 255")
        self.assertEqual(list(report.judge(o, NOW)), ["unreachable"])

    def test_each_failing_step(self) -> None:
        o = healthy()
        o.upgrade_failed = True
        o.nixos_version = "26.11.20261010.abcdef0"
        o.kernel_pending = True
        o.switched_epoch = int((NOW - timedelta(days=3)).timestamp())
        o.behind_by = 4
        o.oldest_missing_epoch = int((NOW - timedelta(hours=40)).timestamp())
        self.assertEqual(set(report.judge(o, NOW)),
                         {"upgrade-failed", "nixpkgs-stale", "reboot-pending", "den-behind-main"})

    def test_recent_main_commits_and_recent_switches_do_not_fail(self) -> None:
        o = healthy()
        o.behind_by = 2
        o.oldest_missing_epoch = int((NOW - timedelta(hours=5)).timestamp())
        o.kernel_pending = True
        o.switched_epoch = int((NOW - timedelta(hours=10)).timestamp())
        self.assertEqual(report.judge(o, NOW), {})

    def test_a_missing_den_commit_fails(self) -> None:
        o = healthy("M-02877")
        o.den_revision = None
        self.assertEqual(list(report.judge(o, NOW)), ["den-revision-unknown"])


class ResolveTests(unittest.TestCase):
    def test_a_build_without_rev_resolves_by_time_and_nar_hash(self) -> None:
        o = report.Observation("paphos", True, nar_hash="sha256-good", last_modified=1793605008)
        calls: list = []
        with patch.object(report, "gh_json", lambda args: calls.append(args) or [{"sha": "b" * 40}, {"sha": "c" * 40}]):
            report.resolve_revision(o, nar_of=lambda sha: "sha256-good" if sha == "c" * 40 else "sha256-other")
        self.assertEqual(o.den_revision, "c" * 40)
        self.assertIn("since=2026-11-02T", calls[0][1])

    def test_no_match_stays_unknown(self) -> None:
        o = report.Observation("paphos", True, nar_hash="sha256-good", last_modified=1793605008)
        with patch.object(report, "gh_json", lambda args: [{"sha": "b" * 40}]):
            report.resolve_revision(o, nar_of=lambda sha: "sha256-other")
        self.assertIsNone(o.den_revision)
        self.assertEqual(list(report.judge(o, NOW)), ["den-revision-unknown"])


class IssuePlanTests(unittest.TestCase):
    def test_opens_once_and_closes_on_pass(self) -> None:
        failing = healthy()
        failing.failures = {"upgrade-failed": "failed"}
        to_open, to_close = report.plan_issue_changes([failing], [])
        self.assertEqual([(h, s) for h, s, _ in to_open], [("paphos", "upgrade-failed")])
        self.assertEqual(to_close, [])
        issues = [{"number": 7, "title": "deploy: paphos: upgrade-failed"}]
        self.assertEqual(report.plan_issue_changes([failing], issues), ([], []))
        passing = healthy()
        to_open, to_close = report.plan_issue_changes([passing], issues)
        self.assertEqual(to_open, [])
        self.assertEqual([n for n, _ in to_close], [7])

    def test_an_unreachable_host_closes_nothing(self) -> None:
        o = report.Observation("paphos", False, error="timeout")
        o.failures = report.judge(o, NOW)
        issues = [{"number": 7, "title": "deploy: paphos: upgrade-failed"},
                  {"number": 8, "title": "deploy: paphos: unreachable"}]
        to_open, to_close = report.plan_issue_changes([o], issues)
        self.assertEqual((to_open, to_close), ([], []))

    def test_other_hosts_and_foreign_titles_are_ignored(self) -> None:
        issues = [{"number": 9, "title": "deploy: oracle: upgrade-failed"}, {"number": 10, "title": "unrelated"}]
        self.assertEqual(report.plan_issue_changes([healthy("paphos")], issues), ([], []))


if __name__ == "__main__":
    unittest.main()
