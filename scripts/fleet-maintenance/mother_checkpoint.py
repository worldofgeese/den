#!/usr/bin/env python3
"""Run the limited Mother checkpoint on loving-kypris. No firmware actions."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from typing import Any, IO
import urllib.error
import urllib.request

import mother_recovery as source

API_URL = "https://zerobyte.hound-celsius.ts.net"
CONTAINER_STAGE = "/var/lib/zerobyte/sources/mother-recovery"
MAX_AGE_SECONDS = 2 * 60 * 60
CLOCK_TOLERANCE_SECONDS = 120
POLL_SECONDS = 5
BACKUP_TIMEOUT_SECONDS = 30 * 60
STAGE_FILES = {"recovery.tar", "source-receipt.json", "exporter.py", "README.md"}
ID = re.compile(r"[A-Za-z0-9]{6,32}")
SHA256 = re.compile(r"[0-9a-f]{64}")
SNAPSHOT_ID = re.compile(r"(?:[0-9a-f]{8}|[0-9a-f]{64})")
SQLITE_WITNESSES = {
    "sonarr.db": "home-volume/taohansen/docker/sonarr/config/",
    "radarr.db": "home-volume/taohansen/docker/radarr/config/",
    "user-db.sqlite": "root-volume/@synologydrive/",
}


class CheckpointError(RuntimeError):
    pass


def read_private(path: Path, limit: int = 65536) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise CheckpointError("A private input file has unsafe ownership or permissions")
        value = handle.read(limit + 1)
        if not value or len(value) > limit:
            raise CheckpointError("A private input file is empty or too large")
        return value


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    fd, temporary = tempfile.mkstemp(prefix=".checkpoint-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


@dataclass(frozen=True)
class Configuration:
    repository_id: str
    backup_id: str
    binding_sha256: str
    data_root: Path
    state_root: Path
    api_key_file: Path
    restic_password_file: Path

    @property
    def staging(self) -> Path:
        return self.data_root / "sources/mother-recovery"

    @property
    def repository(self) -> Path:
        return self.data_root / "repositories/mother-recovery" / self.repository_id

    @classmethod
    def load(cls, path: Path) -> Configuration:
        data = json.loads(read_private(path))
        expected = set(cls.__dataclass_fields__)
        if not isinstance(data, dict) or set(data) != expected:
            raise CheckpointError("The checkpoint configuration has an unsupported schema")
        if any(not isinstance(data[k], str) or ID.fullmatch(data[k]) is None
               for k in ("repository_id", "backup_id")):
            raise CheckpointError("A backup resource identifier is invalid")
        if not isinstance(data["binding_sha256"], str) or SHA256.fullmatch(data["binding_sha256"]) is None:
            raise CheckpointError("The approved backup binding is missing")
        for key in ("data_root", "state_root", "api_key_file", "restic_password_file"):
            value = Path(data[key])
            if not value.is_absolute() or ".." in value.parts or value == Path("/"):
                raise CheckpointError("A configured path is not a bounded absolute path")
            if value.resolve() != value:
                raise CheckpointError("A configured path contains a symlink")
            data[key] = value
        result = cls(**data)
        if result.data_root == result.state_root or result.data_root in result.state_root.parents:
            raise CheckpointError("The journal must stay outside Zerobyte data")
        return result


def binding_digest(job: dict[str, Any]) -> str:
    volatile = {"createdAt", "updatedAt", "lastBackupAt", "lastBackupStatus", "lastBackupError", "nextBackupAt"}
    bound = {key: value for key, value in job.items() if key not in volatile}
    for name, ignored in (
        ("volume", {"createdAt", "updatedAt", "lastHealthCheck", "status", "lastError"}),
        ("repository", {"createdAt", "updatedAt", "lastChecked", "status", "lastError", "doctorResult"}),
    ):
        if not isinstance(bound.get(name), dict):
            raise CheckpointError("The backup resource binding is incomplete")
        bound[name] = {key: value for key, value in bound[name].items() if key not in ignored}
    return hashlib.sha256(json.dumps(bound, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def validate_binding(job: dict[str, Any], config: Configuration) -> None:
    if (job.get("shortId") != config.backup_id or job.get("enabled") is not False
            or not isinstance(job.get("repository"), dict)
            or job["repository"].get("shortId") != config.repository_id
            or job.get("repositoryId") != job["repository"].get("id")
            or not isinstance(job.get("volume"), dict)
            or job["volume"].get("config", {}).get("path") != CONTAINER_STAGE
            or binding_digest(job) != config.binding_sha256):
        raise CheckpointError("The backup configuration differs from its approved binding")


def validate_receipt(receipt: dict[str, Any], now: datetime, requested_at: datetime | None = None) -> None:
    try:
        run_id = source.validate_run_id(receipt["run_id"])
        captured = datetime.strptime(run_id[:16], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
        completed = datetime.fromisoformat(receipt["completed_at"])
        age = (now - captured).total_seconds()
        size = receipt["archive_bytes"]
        valid = (receipt["ready"] is True and type(size) is int and 0 < size <= source.MAX_ARCHIVE_BYTES
                 and isinstance(receipt["archive_sha256"], str)
                 and SHA256.fullmatch(receipt["archive_sha256"]) is not None
                 and completed.tzinfo is not None and captured <= completed <= now
                 and -CLOCK_TOLERANCE_SECONDS <= age <= MAX_AGE_SECONDS)
        if requested_at is not None:
            valid = valid and captured >= requested_at.replace(microsecond=0)
    except (KeyError, TypeError, ValueError, source.RecoveryError):
        valid = False
    if not valid:
        raise CheckpointError("The source receipt is invalid, stale, or from an earlier request")


def completed_snapshot(job: dict[str, Any], snapshots: list[dict[str, Any]], active_tasks: list[Any],
                       before_at: int, before_ids: set[str], trigger_ms: int, backup_id: str) -> str | None:
    at = job.get("lastBackupAt")
    if job.get("lastBackupStatus") == "in_progress" or active_tasks or type(at) is not int or at <= before_at:
        return None
    if job.get("lastBackupStatus") != "success" or job.get("lastBackupError") is not None:
        raise CheckpointError("The new backup did not finish with an unqualified success")
    matches = []
    for snapshot in snapshots:
        identifier = snapshot.get("short_id")
        stamp = snapshot.get("time")
        if (isinstance(identifier, str) and SNAPSHOT_ID.fullmatch(identifier)
                and identifier not in before_ids and type(stamp) is int and stamp >= trigger_ms
                and backup_id in snapshot.get("tags", []) and snapshot.get("paths") == [CONTAINER_STAGE]):
            matches.append(identifier)
    if len(matches) > 1:
        raise CheckpointError("More than one new snapshot matches this request")
    return matches[0] if matches else None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        raise CheckpointError("The authenticated API request changed its destination")


def api(config: Configuration, method: str, path: str) -> Any:
    key = read_private(config.api_key_file, 8192).decode().strip()
    request = urllib.request.Request(API_URL + path, data=b"{}" if method == "POST" else None,
                                     headers={"x-api-key": key, "Content-Type": "application/json", "Origin": API_URL},
                                     method=method)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        with opener.open(request, timeout=20) as response:
            value = response.read(2 * 1024**2 + 1)
            if len(value) > 2 * 1024**2:
                raise CheckpointError("The API response exceeded its size limit")
            return json.loads(value)
    except urllib.error.HTTPError as error:
        raise CheckpointError(f"The Zerobyte API returned HTTP {error.code}") from None


def ssh_command(action: str, run_id: str | None, seconds: int) -> list[str]:
    if action not in {"plan", "prepare", "stream", "cleanup"}:
        raise CheckpointError("Unsupported NAS action")
    arguments = [action]
    if run_id is not None:
        arguments.append(source.validate_run_id(run_id))
    return ["timeout", "--kill-after=10s", str(seconds), "ssh", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3", "-p", "2235", "taohansen@192.168.99.200",
            "sudo", "-n", "python3", "-", *arguments]


def nas_json(action: str, helper: bytes, run_id: str | None = None) -> dict[str, Any]:
    result = subprocess.run(ssh_command(action, run_id, 7200 if action == "prepare" else 300),
                            input=helper, capture_output=True, timeout=7220 if action == "prepare" else 320)
    if result.returncode or len(result.stdout) > 1024**2:
        raise CheckpointError(f"The NAS {action} operation failed")
    value = json.loads(result.stdout)
    if not isinstance(value, dict):
        raise CheckpointError("The NAS returned an unsupported response")
    return value


def copy_bounded(input_file: IO[bytes], output_file: IO[bytes], expected_bytes: int) -> str:
    count = 0
    digest = hashlib.sha256()
    while block := input_file.read(1024**2):
        count += len(block)
        if count > expected_bytes:
            raise CheckpointError("The archive stream exceeded its declared size")
        output_file.write(block)
        digest.update(block)
    if count != expected_bytes:
        raise CheckpointError("The archive stream is incomplete")
    return digest.hexdigest()


def transfer(config: Configuration, helper: bytes, receipt: dict[str, Any]) -> None:
    source.require_private_directory(config.staging)
    if list(config.staging.iterdir()):
        raise CheckpointError("The private source directory is not empty")
    with tempfile.TemporaryDirectory(prefix=".mother-transfer-", dir=config.staging.parent) as temporary:
        archive = Path(temporary) / "recovery.tar"
        with tempfile.TemporaryFile() as errors, archive.open("xb") as output:
            process = subprocess.Popen(ssh_command("stream", receipt["run_id"], 1800),
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
            try:
                assert process.stdin is not None and process.stdout is not None
                process.stdin.write(helper)
                process.stdin.close()
                actual = copy_bounded(process.stdout, output, receipt["archive_bytes"])
                if process.wait(timeout=30) or actual != receipt["archive_sha256"]:
                    raise CheckpointError("The transferred archive failed its size or hash check")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
        archive.chmod(0o400)
        os.link(archive, config.staging / "recovery.tar")
    files = {"source-receipt.json": json.dumps(receipt, sort_keys=True).encode(), "exporter.py": helper,
             "README.md": Path(__file__).with_name("README.md").read_bytes()}
    for name, content in files.items():
        fd = os.open(config.staging / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
        (config.staging / name).chmod(0o400)


def restic(config: Configuration, arguments: list[str], output: IO[bytes] | None = None,
           expected_bytes: int | None = None) -> None:
    read_private(config.restic_password_file, 8192)
    environment = os.environ.copy()
    environment.pop("RESTIC_PASSWORD", None)
    environment.pop("RESTIC_PASSWORD_COMMAND", None)
    environment["RESTIC_PASSWORD_FILE"] = str(config.restic_password_file)
    environment["RESTIC_CACHE_DIR"] = str(config.state_root / "restic-cache")
    command = ["timeout", "--kill-after=10s", "3600", "restic", "--repo", str(config.repository), *arguments]
    with tempfile.TemporaryFile() as log:
        if output is None:
            result = subprocess.run(command, env=environment, stdout=log, stderr=log, timeout=3620)
            code = result.returncode
        else:
            if expected_bytes is None or not 0 < expected_bytes <= source.MAX_ARCHIVE_BYTES:
                raise CheckpointError("A bounded restore size is required")
            process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=log)
            try:
                assert process.stdout is not None
                copy_bounded(process.stdout, output, expected_bytes)
                code = process.wait(timeout=30)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
        if code:
            raise CheckpointError("Independent Restic verification failed")


def inspect_archive(path: Path, receipt: dict[str, Any], destination: Path) -> dict[str, Any]:
    if path.stat().st_size != receipt["archive_bytes"] or source.sha256(path) != receipt["archive_sha256"]:
        raise CheckpointError("The restored archive does not match the source receipt")
    manifest: dict[str, Any] | None = None
    databases: set[str] = set()
    source_roots: list[str] = []
    expected_exports: set[str] = set()
    seen: set[str] = set()
    required_files = {"manifest.json", "containers.json", "exports/postgres/globals.sql"}
    regular_files: set[str] = set()
    witnesses: dict[str, dict[str, tarfile.TarInfo]] = {name: {} for name in SQLITE_WITNESSES}
    entries = 0
    with tarfile.open(path, "r:") as archive:
        for member in archive:
            entries += 1
            name = member.name.removeprefix("./")
            parts = PurePosixPath(name)
            if (entries > 1_000_000 or parts.is_absolute() or ".." in parts.parts or name in seen
                    or any(name == p or name.startswith(p + "/") for p in source.EXCLUDES)):
                raise CheckpointError("The archive contains an unsafe, duplicate, or excluded member")
            seen.add(name)
            if member.isfile():
                regular_files.add(name)
            if name == "manifest.json":
                if manifest is not None or not member.isfile() or member.size > 1024**2:
                    raise CheckpointError("The archive manifest is invalid")
                handle = archive.extractfile(member)
                assert handle is not None
                manifest = json.load(handle)
                if (not isinstance(manifest, dict) or manifest.get("schema") != 1
                        or manifest.get("run_id") != receipt["run_id"]
                        or manifest.get("archive_excludes") != list(source.EXCLUDES)
                        or not isinstance(manifest.get("sources"), list) or not manifest["sources"]
                        or not isinstance(manifest.get("postgres_exports"), list) or not manifest["postgres_exports"]):
                    raise CheckpointError("The restored manifest has an invalid schema or recovery scope")
                try:
                    source_roots = [source.archive_member(Path(value)) for value in manifest["sources"]]
                except (TypeError, source.RecoveryError):
                    raise CheckpointError("The manifest includes an unapproved source") from None
                names = manifest["postgres_exports"]
                if any(not isinstance(value, str) or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]{0,62}", value) is None
                       for value in names) or len(set(names)) != len(names):
                    raise CheckpointError("The manifest has an invalid database export list")
                expected_exports = {f"exports/postgres/{value}.dump" for value in names}
            elif manifest is None:
                raise CheckpointError("The archive must start with its manifest")
            allowed = (name in required_files or name in expected_exports
                       or any(name == root or name.startswith(root + "/") for root in source_roots)
                       or member.isdir() and (name in {"exports", "exports/postgres"}
                                              or any(root.startswith(name.rstrip("/") + "/") for root in source_roots)))
            if not allowed:
                raise CheckpointError("The archive contains data outside its approved sources")
            if name.startswith("exports/postgres/") and name.endswith(".dump"):
                if not member.isfile() or name in databases:
                    raise CheckpointError("A database export is not a unique regular file")
                handle = archive.extractfile(member)
                assert handle is not None
                if handle.read(5) != b"PGDMP":
                    raise CheckpointError("A PostgreSQL export has an invalid header")
                databases.add(name)
            for basename, prefix in SQLITE_WITNESSES.items():
                if name.startswith(prefix) and parts.name in {basename, basename + "-wal", basename + "-shm"}:
                    if not member.isfile() or parts.name in witnesses[basename]:
                        raise CheckpointError("A SQLite witness is ambiguous or is not a regular file")
                    witnesses[basename][parts.name] = member
        if manifest is None or databases != expected_exports or not required_files <= regular_files:
            raise CheckpointError("The archive lacks a required recovery artifact")
        for basename, members in witnesses.items():
            if basename not in members:
                raise CheckpointError("A required SQLite witness is absent")
            parent = PurePosixPath(members[basename].name).parent
            if any(PurePosixPath(member.name).parent != parent for member in members.values()):
                raise CheckpointError("A SQLite sidecar belongs to another directory")
            folder = destination / basename
            folder.mkdir(mode=0o700)
            for name, member in members.items():
                input_file = archive.extractfile(member)
                assert input_file is not None
                with (folder / name).open("xb") as output_file:
                    shutil.copyfileobj(input_file, output_file)
            with sqlite3.connect(str(folder / basename)) as database:
                if database.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
                    raise CheckpointError("A restored SQLite database failed its integrity check")
    return {"archive_entries": entries, "sqlite_witnesses": sorted(witnesses), "postgres_exports": len(databases)}


def checkpoint(config: Configuration, execute: bool) -> dict[str, Any]:
    os.umask(0o077)
    config.state_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    source.require_private_directory(config.state_root)
    lock_fd = os.open(config.state_root / "checkpoint.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        job_path = f"/api/v1/backups/{config.backup_id}"
        snapshot_path = f"/api/v1/repositories/{config.repository_id}/snapshots?backupId={config.backup_id}"
        task_path = f"/api/v1/tasks?kind=backup&resourceType=backup_schedule&resourceId={config.backup_id}"
        job = api(config, "GET", job_path)
        validate_binding(job, config)
        read_private(config.restic_password_file, 8192)
        if not config.repository.is_dir() or config.repository.is_symlink():
            raise CheckpointError("The dedicated encrypted repository is absent")
        if not all(shutil.which(program) for program in ("ssh", "timeout", "restic")):
            raise CheckpointError("A required local program is absent")
        if shutil.disk_usage(config.data_root).free < 3 * source.MAX_ARCHIVE_BYTES + 10 * 1024**3:
            raise CheckpointError("There is insufficient space for transfer and independent restoration")
        if api(config, "GET", task_path) or job.get("lastBackupStatus") == "in_progress":
            raise CheckpointError("The dedicated backup already has an active task")
        if config.staging.exists() or config.staging.is_symlink():
            source.require_private_directory(config.staging)
            if list(config.staging.iterdir()):
                raise CheckpointError("A previous temporary source requires review")
        if not execute:
            return {"status": "local_preflight_passed", "nas_checked": False,
                    "backup_id": config.backup_id, "repository_id": config.repository_id}
        journal = config.state_root / "checkpoint.json"
        if journal.exists() and json.loads(read_private(journal)).get("status") != "verified":
            raise CheckpointError("The preceding attempt requires review before another backup")
        helper = Path(source.__file__).read_bytes()
        requested = datetime.now(timezone.utc)
        state: dict[str, Any] = {"schema": 1, "status": "running", "phase": "prepare", "started_at": requested.isoformat()}
        atomic_json(journal, state)
        try:
            receipt = nas_json("prepare", helper)
            validate_receipt(receipt, datetime.now(timezone.utc), requested)
            state.update({"phase": "transfer", "receipt": receipt})
            atomic_json(journal, state)
            config.staging.mkdir(mode=0o700, parents=True, exist_ok=True)
            transfer(config, helper, receipt)
            validate_receipt(receipt, datetime.now(timezone.utc))
            job = api(config, "GET", job_path)
            validate_binding(job, config)
            if api(config, "GET", task_path) or job.get("lastBackupStatus") == "in_progress":
                raise CheckpointError("Another backup started before this trigger")
            before_at = job.get("lastBackupAt") or 0
            before = api(config, "GET", snapshot_path)
            before_ids = {item["short_id"] for item in before}
            trigger_ms = time.time_ns() // 1_000_000
            state.update({"phase": "backup_requested", "before_at": before_at,
                          "before_snapshots": sorted(before_ids), "trigger_ms": trigger_ms})
            atomic_json(journal, state)
            api(config, "POST", job_path + "/run")
            deadline = time.monotonic() + BACKUP_TIMEOUT_SECONDS
            snapshot = None
            while time.monotonic() < deadline:
                snapshot = completed_snapshot(api(config, "GET", job_path), api(config, "GET", snapshot_path),
                                              api(config, "GET", task_path), before_at, before_ids, trigger_ms, config.backup_id)
                if snapshot:
                    break
                time.sleep(POLL_SECONDS)
            if snapshot is None:
                raise CheckpointError("The backup did not produce a new confirmed snapshot before the deadline")
            state.update({"phase": "verify", "snapshot": snapshot})
            atomic_json(journal, state)
            restic(config, ["check", "--read-data"])
            with tempfile.TemporaryDirectory(prefix=".mother-restore-", dir=config.data_root) as temporary:
                root = Path(temporary)
                with (root / "recovery.tar").open("xb") as output:
                    restic(config, ["dump", snapshot, CONTAINER_STAGE + "/recovery.tar"], output, receipt["archive_bytes"])
                proof = inspect_archive(root / "recovery.tar", receipt, root)
            state.update({"phase": "cleanup", "restore_proof": proof})
            atomic_json(journal, state)
            if {p.name for p in config.staging.iterdir()} != STAGE_FILES:
                raise CheckpointError("The private source directory contains unexpected files")
            for name in STAGE_FILES:
                info = (config.staging / name).lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
                    raise CheckpointError("A temporary file has unsafe type, ownership, or permissions")
            if json.loads(read_private(config.staging / "source-receipt.json")) != receipt:
                raise CheckpointError("The temporary source belongs to another run")
            if source.sha256(config.staging / "recovery.tar") != receipt["archive_sha256"]:
                raise CheckpointError("The temporary archive changed after the backup")
            nas_json("cleanup", helper, receipt["run_id"])
            for name in STAGE_FILES:
                path = config.staging / name
                if not path.is_file() or path.is_symlink():
                    raise CheckpointError("A temporary file changed type before cleanup")
                path.unlink()
            state.update({"status": "verified", "phase": "complete", "finished_at": datetime.now(timezone.utc).isoformat()})
            atomic_json(journal, state)
            return state
        except BaseException as error:
            state.update({"status": "failed", "error_type": type(error).__name__})
            atomic_json(journal, state)
            raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--execute", action="store_true", help="Prepare, back up, restore, and clean this dedicated source")
    args = parser.parse_args()
    try:
        result = checkpoint(Configuration.load(args.config), args.execute)
        print(json.dumps(result, sort_keys=True))
    except Exception as error:
        print(json.dumps({"status": "failed", "error_type": type(error).__name__,
                          "message": str(error) if isinstance(error, CheckpointError) else "Checkpoint operation failed"}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
