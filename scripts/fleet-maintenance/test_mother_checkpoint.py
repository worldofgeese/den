from __future__ import annotations

from copy import deepcopy
from dataclasses import replace
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
from pathlib import Path
import sqlite3
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch
from typing import Any, IO

import mother_checkpoint as checkpoint
import mother_recovery as source


class CheckpointTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.data = self.root / "data"
        self.data.mkdir(mode=0o700)
        self.state = self.root / "state"
        self.key = self.root / "api-key"
        self.password = self.root / "restic-key"
        for path in (self.key, self.password):
            path.write_text("PRIVATE_TEST_VALUE\n")
            path.chmod(0o600)
        self.config = checkpoint.Configuration("repo1234", "job12345", "0" * 64, self.data,
                                              self.state, self.key, self.password)
        self.config.repository.mkdir(mode=0o700, parents=True)
        self.job: dict[str, Any] = {
            "id": 10, "shortId": "job12345", "enabled": False, "repositoryId": "repository-uuid",
            "volumeId": 18, "includePaths": [], "excludePatterns": [], "maxRetries": 0,
            "retentionPolicy": {"keepLast": 7}, "lastBackupAt": 1, "lastBackupStatus": "success",
            "lastBackupError": None,
            "volume": {"id": 18, "config": {"backend": "local", "path": checkpoint.CONTAINER_STAGE},
                       "status": "available", "lastError": None},
            "repository": {"id": "repository-uuid", "shortId": "repo1234",
                           "config": {"backend": "local", "path": "/repositories/mother-recovery"}},
        }
        self.config = replace(self.config, binding_sha256=checkpoint.binding_digest(self.job))
        self.now = datetime.now(timezone.utc)
        self.receipt: dict[str, Any] = {"run_id": self.now.strftime("%Y%m%dT%H%M%SZ-") + "0123456789ab", "ready": True,
                        "archive_bytes": 1, "archive_sha256": "a" * 64, "completed_at": self.now.isoformat()}

    def snapshot(self, **changes: object) -> dict:
        result: dict[str, Any] = {"short_id": "abcdef12", "time": 2000, "tags": ["job12345"],
                  "paths": [checkpoint.CONTAINER_STAGE]}
        result.update(changes)
        return result

    def test_a_prior_success_cannot_complete_a_new_run(self) -> None:
        self.assertIsNone(checkpoint.completed_snapshot(self.job, [self.snapshot()], [], 1,
                                                       set(), 1000, "job12345"))
        self.job["lastBackupAt"] = 2001
        self.assertIsNone(checkpoint.completed_snapshot(self.job, [self.snapshot()], [], 1,
                                                       {"abcdef12"}, 1000, "job12345"))
        self.assertEqual(checkpoint.completed_snapshot(self.job, [self.snapshot()], [], 1,
                                                       set(), 1000, "job12345"), "abcdef12")

    def test_active_tasks_old_times_and_wrong_bindings_do_not_pass(self) -> None:
        self.job["lastBackupAt"] = 2001
        self.assertIsNone(checkpoint.completed_snapshot(self.job, [self.snapshot()], [{}], 1,
                                                       set(), 1000, "job12345"))
        for change in ({"time": 999}, {"tags": ["other"]}, {"paths": ["/other"]},
                       {"short_id": "../bad"}, {"time": True}):
            with self.subTest(change=change):
                self.assertIsNone(checkpoint.completed_snapshot(self.job, [self.snapshot(**change)], [], 1,
                                                               set(), 1000, "job12345"))

    def test_partial_backup_and_multiple_new_snapshots_fail(self) -> None:
        self.job["lastBackupAt"] = 2001
        for status in ("warning", "error", None, "unknown"):
            self.job["lastBackupStatus"] = status
            with self.subTest(status=status), self.assertRaises(checkpoint.CheckpointError):
                checkpoint.completed_snapshot(self.job, [self.snapshot()], [], 1, set(), 1000, "job12345")
        self.job["lastBackupStatus"] = "success"
        self.job["lastBackupError"] = "retained error"
        with self.assertRaises(checkpoint.CheckpointError):
            checkpoint.completed_snapshot(self.job, [self.snapshot()], [], 1, set(), 1000, "job12345")
        self.job["lastBackupError"] = None
        with self.assertRaises(checkpoint.CheckpointError):
            checkpoint.completed_snapshot(self.job, [self.snapshot(), self.snapshot(short_id="aabbccdd")], [],
                                          1, set(), 1000, "job12345")

    def test_source_receipt_requires_fresh_complete_bounded_data(self) -> None:
        checkpoint.validate_receipt(self.receipt, self.now)
        for change in ({"ready": False}, {"archive_bytes": True}, {"archive_bytes": 0},
                       {"archive_bytes": source.MAX_ARCHIVE_BYTES + 1}, {"archive_sha256": "bad"},
                       {"run_id": "../other"}, {"completed_at": "2026-11-01T12:00:00"}):
            with self.subTest(change=change), self.assertRaises(checkpoint.CheckpointError):
                checkpoint.validate_receipt({**self.receipt, **change}, self.now)
        with self.assertRaises(checkpoint.CheckpointError):
            checkpoint.validate_receipt(self.receipt, self.now + timedelta(hours=3))
        with self.assertRaises(checkpoint.CheckpointError):
            checkpoint.validate_receipt(self.receipt, self.now, self.now + timedelta(seconds=5))

    def test_binding_excludes_health_but_not_scope(self) -> None:
        checkpoint.validate_binding(self.job, self.config)
        changed = deepcopy(self.job)
        changed["lastBackupAt"] = 5000
        changed["volume"]["status"] = "unavailable"
        changed["volume"]["lastError"] = "offline"
        checkpoint.validate_binding(changed, self.config)
        for field, value in (("enabled", True), ("includePaths", ["/other"]), ("repositoryId", "other")):
            with self.subTest(field=field), self.assertRaises(checkpoint.CheckpointError):
                checkpoint.validate_binding({**self.job, field: value}, self.config)
        changed["volume"]["config"]["path"] = "/other"
        with self.assertRaises(checkpoint.CheckpointError):
            checkpoint.validate_binding(changed, self.config)

    def test_private_inputs_reject_symlinks_and_public_permissions(self) -> None:
        self.assertEqual(checkpoint.read_private(self.key), b"PRIVATE_TEST_VALUE\n")
        link = self.root / "link"
        link.symlink_to(self.key)
        with self.assertRaises(OSError):
            checkpoint.read_private(link)
        self.key.chmod(0o644)
        with self.assertRaises(checkpoint.CheckpointError):
            checkpoint.read_private(self.key)

    def test_archive_copy_is_bounded_and_complete(self) -> None:
        output = io.BytesIO()
        self.assertEqual(checkpoint.copy_bounded(io.BytesIO(b"data"), output, 4), hashlib.sha256(b"data").hexdigest())
        for value in (b"dat", b"extra"):
            with self.assertRaises(checkpoint.CheckpointError):
                checkpoint.copy_bounded(io.BytesIO(value), io.BytesIO(), 4)

    def make_archive(self, extra: str | None = None) -> Path:
        db = self.root / "sample.db"
        with sqlite3.connect(db) as connection:
            connection.execute("CREATE TABLE IF NOT EXISTS example (value INTEGER)")
        manifest = {"schema": 1, "run_id": self.receipt["run_id"], "archive_excludes": list(source.EXCLUDES),
                    "postgres_exports": ["example"],
                    "sources": ["/volume1/homes/taohansen/docker/sonarr/config",
                                "/volume1/homes/taohansen/docker/radarr/config", "/volume1/@synologydrive"]}
        members = {"manifest.json": json.dumps(manifest).encode(), "containers.json": b'{"containers":[]}',
                   "exports/postgres/globals.sql": b"-- fixture roles\n", "exports/postgres/example.dump": b"PGDMPtest"}
        for basename, prefix in checkpoint.SQLITE_WITNESSES.items():
            members[prefix + basename] = db.read_bytes()
        if extra:
            members[extra] = b"unexpected"
        archive = self.root / "source.tar"
        with tarfile.open(archive, "w") as bundle:
            for name, value in members.items():
                info = tarfile.TarInfo(name)
                info.size = len(value)
                bundle.addfile(info, io.BytesIO(value))
        self.receipt.update({"archive_bytes": archive.stat().st_size, "archive_sha256": source.sha256(archive)})
        return archive

    def test_restored_archive_checks_database_witnesses(self) -> None:
        archive = self.make_archive()
        target = self.root / "witnesses"
        target.mkdir()
        proof = checkpoint.inspect_archive(archive, self.receipt, target)
        self.assertEqual(proof["postgres_exports"], 1)
        self.assertEqual(len(proof["sqlite_witnesses"]), 3)

    def test_restore_refuses_path_escape_excluded_data_and_unknown_sources(self) -> None:
        for name in ("../escape", source.EXCLUDES[0] + "/large-file", "unapproved/data"):
            with self.subTest(name=name):
                archive = self.make_archive(name)
                target = self.root / ("witness-" + hashlib.sha256(name.encode()).hexdigest()[:8])
                target.mkdir()
                with self.assertRaises(checkpoint.CheckpointError):
                    checkpoint.inspect_archive(archive, self.receipt, target)

    def test_full_pipeline_requires_new_snapshot_and_restore_before_cleanup(self) -> None:
        archive = self.make_archive()
        original = archive.read_bytes()
        events: list[str] = []
        posted = False

        def fake_api(config: checkpoint.Configuration, method: str, path: str) -> object:
            nonlocal posted
            if method == "POST":
                posted = True
                events.append("post")
                return {"taskId": "one"}
            if "/tasks?" in path:
                return []
            if "/snapshots?" in path:
                return [self.snapshot(time=time.time_ns() // 1_000_000)] if posted else []
            job = deepcopy(self.job)
            if posted:
                job["lastBackupAt"] = time.time_ns() // 1_000_000
            return job

        def fake_nas(action: str, helper: bytes, run_id: str | None = None) -> dict:
            events.append(action)
            return self.receipt if action == "prepare" else {"cleaned": True}

        def fake_transfer(config: checkpoint.Configuration, helper: bytes, receipt: dict) -> None:
            (config.staging / "recovery.tar").write_bytes(original)
            checkpoint.atomic_json(config.staging / "source-receipt.json", receipt)
            for name in ("exporter.py", "README.md"):
                (config.staging / name).write_text("fixture")

        def fake_restic(config: checkpoint.Configuration, arguments: list[str], output: IO[bytes] | None = None,
                        expected_bytes: int | None = None) -> None:
            events.append(arguments[0])
            if output is not None:
                self.assertEqual(expected_bytes, len(original))
                output.write(original)

        with patch.object(checkpoint, "datetime", wraps=datetime) as clock, \
                patch.object(checkpoint, "api", side_effect=fake_api), \
                patch.object(checkpoint, "nas_json", side_effect=fake_nas), \
                patch.object(checkpoint, "transfer", side_effect=fake_transfer), \
                patch.object(checkpoint, "restic", side_effect=fake_restic), \
                patch.object(checkpoint.shutil, "which", return_value="/bin/mock"), \
                patch.object(checkpoint.shutil, "disk_usage", return_value=type("Space", (), {"free": 200 * 1024**3})()):
            clock.now.return_value = self.now
            result = checkpoint.checkpoint(self.config, True)
        self.assertEqual(result["status"], "verified")
        self.assertEqual(events, ["prepare", "post", "check", "dump", "cleanup"])
        self.assertEqual(list(self.config.staging.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
