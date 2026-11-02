#!/usr/bin/env python3
"""Prepare a bounded recovery archive on mother. Python 3.8 is the DSM runtime."""
from __future__ import annotations

import argparse
from contextlib import closing
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Sequence, Tuple

WORK_ROOT = Path("/volume1/@fleet-recovery")
MAX_SOURCE_BYTES = 20 * 1024**3
MAX_ARCHIVE_BYTES = 24 * 1024**3
MIN_FREE_BYTES = 32 * 1024**3
DOCKER = "/var/packages/ContainerManager/target/usr/bin/docker"
RUN_ID = re.compile(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}")

EXPECTED_MOUNTS = {
    "sonarr": {"/config": "/volume1/homes/taohansen/docker/sonarr/config"},
    "transmission": {"/config": "/volume1/homes/taohansen/docker/transmission/config"},
    "tang": {"/var/db/tang": "/volume1/@tang-db"},
    "seerr": {"/app/config": "/volume1/homes/taohansen/docker/seerr/config"},
    "bazarr": {"/config": "/volume1/homes/taohansen/docker/bazarr/config"},
    "radarr": {"/config": "/volume1/homes/taohansen/docker/radarr/config"},
    "cloudflared": {},
    "nzbget": {"/config": "/volume1/homes/taohansen/docker/nzbget/config"},
    "jellyfin": {"/config": "/volume1/homes/taohansen/docker/jellyfin-sqlite-stage-20260620T170159Z"},
    "tdarr": {
        "/app/configs": "/volume1/homes/taohansen/docker/tdarr/configs",
        "/app/server": "/volume1/homes/taohansen/docker/tdarr/server",
    },
    "openspeedtest": {},
    "gluetun": {"/gluetun": "/volume1/homes/taohansen/docker/gluetun"},
    "dockhand": {"/app/data": "/volume1/homes/taohansen/docker/dockhand/data"},
}
EXCLUDED_MOUNT_DESTINATIONS = {
    "/downloads", "/downloads/nzbget", "/intermediate", "/tv", "/movies", "/media/music",
    "/media/movies", "/media/tv", "/data/movies", "/data/tvshows",
    "/cache", "/temp", "/app/logs", "/var/log/letsencrypt",
    "/etc/localtime", "/var/run/docker.sock", "/config/data/transcodes",
}
FIXED_SOURCES = {
    Path("/etc"), Path("/usr/syno/etc"), Path("/usr/local/etc"),
    Path("/usr/local/bin"), Path("/usr/local/sbin"),
    Path("/volume1/@database/pgsql"), Path("/volume1/@synologydrive"),
    Path("/volume1/@appconf"), Path("/volume1/@tang-db"),
    Path("/volume1/homes/taohansen/.ssh"),
}
CONTAINER_SOURCES = {Path(p) for mounts in EXPECTED_MOUNTS.values() for p in mounts.values()}
PACKAGE_ROOTS = (Path("/volume1/@appdata"), Path("/usr/local/packages/@appdata"),
                 Path("/volume1/@apphome"), Path("/usr/local/packages/@apphome"))
EXCLUDES = (
    "root-volume/@synologydrive/@sync/repo",
    "root-volume/@appdata/ContainerManager/all_shares",
)


class RecoveryError(RuntimeError):
    pass


def validate_run_id(value: str) -> str:
    if RUN_ID.fullmatch(value) is None:
        raise RecoveryError("Invalid recovery run identifier")
    return value


def validate_source(path: Path) -> None:
    if not path.is_absolute() or ".." in path.parts:
        raise RecoveryError("Recovery source is not a canonical absolute path")
    if path in FIXED_SOURCES or path in CONTAINER_SOURCES:
        return
    if path.parent in PACKAGE_ROOTS and re.fullmatch(r"[A-Za-z0-9_.+-]+", path.name):
        return
    if (path.parent.parent == Path("/var/packages") and path.name in ("var", "home")
            and re.fullmatch(r"[A-Za-z0-9_.+-]+", path.parent.name)):
        return
    raise RecoveryError("Recovery source is outside the approved allowlist")


def archive_member(path: Path) -> str:
    validate_source(path)
    try:
        return "home-volume/" + str(path.relative_to("/volume1/homes"))
    except ValueError:
        pass
    try:
        return "root-volume/" + str(path.relative_to("/volume1"))
    except ValueError:
        return "system/" + str(path.relative_to("/"))


def validate_raid(text: str) -> None:
    arrays = re.findall(r"\[([0-9]+)/([0-9]+)\]\s+\[([U_]+)\]", text)
    if not arrays or any(total != active or "_" in members for total, active, members in arrays):
        raise RecoveryError("RAID health is unknown or degraded")


def validate_subvolume_coverage(sources: List[Path], listing: str) -> None:
    paths = [line.split(" path ", 1)[1] for line in listing.splitlines() if line.startswith("ID ") and " path " in line]
    if "@syno/homes" not in paths and "homes" not in paths:
        raise RecoveryError("Cannot establish the NAS subvolume layout")
    excluded = (Path("/volume1/@synologydrive/@sync/repo"),
                Path("/volume1/@appdata/ContainerManager/all_shares"))
    for text in paths:
        if text == "@syno":
            continue
        relative = text[len("@syno/"):] if text.startswith("@syno/") else text
        if Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise RecoveryError("Unsupported subvolume path format")
        nested = Path("/volume1") / relative
        if nested == Path("/volume1/homes") or any(nested == p or p in nested.parents for p in excluded):
            continue
        if any(nested == p or p in nested.parents or nested in p.parents for p in sources):
            raise RecoveryError("A nested subvolume requires an explicit recovery snapshot")


def validate_containers(containers: List[Dict[str, Any]]) -> None:
    if not isinstance(containers, list) or any(
        not isinstance(c, dict) or not isinstance(c.get("Name"), str)
        or not isinstance(c.get("Mounts"), list)
        or any(not isinstance(m, dict) or not isinstance(m.get("Source"), str)
               or not isinstance(m.get("Destination"), str) for m in c.get("Mounts", []))
        for c in containers
    ):
        raise RecoveryError("Container inspection has an invalid schema")
    by_name = {c.get("Name", "").lstrip("/"): c for c in containers}
    if set(by_name) != set(EXPECTED_MOUNTS):
        raise RecoveryError("Container coverage changed; review the recovery allowlist")
    for name, expected in EXPECTED_MOUNTS.items():
        actual = {m.get("Destination"): m.get("Source") for m in by_name[name].get("Mounts", [])}
        if any(actual.get(destination) != source for destination, source in expected.items()):
            raise RecoveryError("Application mount changed: " + name)
        if set(actual) - set(expected) - EXCLUDED_MOUNT_DESTINATIONS:
            raise RecoveryError("An unclassified persistent mount requires review: " + name)


def require_private_directory(path: Path) -> None:
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise RecoveryError("Recovery directory is not private and owned by the current user")


def run_command(args: Sequence[str], timeout: int = 60) -> str:
    result = subprocess.run(list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=timeout)
    if result.returncode:
        # Output can contain configuration or database material. Never send it to logs.
        raise RecoveryError("{} failed with exit {}".format(Path(args[0]).name, result.returncode))
    return result.stdout


def private_json(path: Path, value: Dict[str, Any]) -> None:
    fd, temporary = tempfile.mkstemp(prefix=".json-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, str(path))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def inspect_containers() -> List[Dict[str, Any]]:
    ids = run_command([DOCKER, "ps", "-aq"]).split()
    if not ids:
        raise RecoveryError("No containers found")
    result = json.loads(run_command([DOCKER, "inspect", *ids]))
    validate_containers(result)
    return result


def container_identity(containers: List[Dict[str, Any]]) -> str:
    identity: List[Dict[str, Any]] = [
        {k: c.get(k) for k in ("Id", "Name", "Image", "Config", "Mounts")} for c in containers
    ]
    for row in identity:
        # Docker returns mount objects in map order; their complete contents still count.
        row["Mounts"] = sorted(row["Mounts"], key=lambda mount: json.dumps(mount, sort_keys=True))
    identity.sort(key=lambda row: str(row["Name"]))
    return hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()


def package_sources(root: Path) -> List[Path]:
    sources = []
    for package in root.iterdir():
        for name in ("var", "home"):
            path = package / name
            if path.exists() or path.is_symlink():
                if not path.is_dir():
                    raise RecoveryError("Package state is not a directory")
                sources.append(path.resolve(strict=True))
    return sources


def collect_sources() -> List[Path]:
    sources = set(CONTAINER_SOURCES)
    for path in FIXED_SOURCES:
        if path.exists():
            sources.add(path)
    sources.update(package_sources(Path("/var/packages")))
    for path in sources:
        validate_source(path)
        if not path.is_dir():
            raise RecoveryError("Recovery source is not a directory")
        if path.resolve(strict=True) != path:
            raise RecoveryError("Recovery source resolves outside its declared path")
    return sorted(sources)


def require_nas_root() -> None:
    if os.geteuid() != 0 or not Path("/etc.defaults/VERSION").is_file() or not Path("/usr/syno").is_dir():
        raise RecoveryError("This command requires root on the Synology NAS")


def preflight() -> Dict[str, Any]:
    require_nas_root()
    for tool in ("btrfs", "tar", "rsync", "psql", "pg_dump", "pg_dumpall", "pg_restore"):
        if shutil.which(tool) is None:
            raise RecoveryError("Required tool is missing: " + tool)
    validate_raid(Path("/proc/mdstat").read_text())
    if shutil.disk_usage("/volume1").free < MIN_FREE_BYTES + MAX_SOURCE_BYTES + MAX_ARCHIVE_BYTES:
        raise RecoveryError("Insufficient free space for a recovery archive")
    for path in ("/volume1", "/volume1/homes"):
        run_command(["btrfs", "subvolume", "show", path])
    if any(Path("/volume1/@database/pgsql/pg_tblspc").iterdir()):
        raise RecoveryError("External PostgreSQL tablespaces require a recovery-scope review")
    containers = inspect_containers()
    sources = collect_sources()
    validate_subvolume_coverage(sources, run_command(["btrfs", "subvolume", "list", "/volume1"], timeout=120))
    return {"sources": [str(p) for p in sources], "container_identity": container_identity(containers),
            "containers": containers}


def tar_command(work: Path, members: List[str]) -> List[str]:
    return ["tar", "--create", "--file", str(work / "recovery.tar"), "--format=posix",
            "--pax-option=delete=atime,delete=ctime", "--sort=name", "--numeric-owner",
            "--sparse", "--acls", "--xattrs", "--xattrs-include=*",
            *["--exclude=" + pattern for pattern in EXCLUDES],
            "--directory", str(work), "--", *members]


def snapshot_uuid(path: Path) -> str:
    output = run_command(["btrfs", "subvolume", "show", str(path)])
    match = re.search(r"^\s*UUID:\s*([0-9a-f-]+)\s*$", output, re.MULTILINE)
    if match is None:
        raise RecoveryError("Cannot identify the owned snapshot")
    return match.group(1)


def stabilize_sqlite(source: Path, target: Path) -> None:
    for directory, folders, files in os.walk(str(source), followlinks=False):
        folders[:] = [name for name in folders if not (Path(directory) / name).is_symlink()]
        for name in files:
            original = Path(directory) / name
            if original.is_symlink() or not original.is_file():
                continue
            with original.open("rb") as input_file:
                if input_file.read(16) != b"SQLite format 3\x00":
                    continue
            destination = target / original.relative_to(source)
            if not destination.is_file() or destination.is_symlink():
                raise RecoveryError("System database changed after its file copy")
            fd, temporary = tempfile.mkstemp(prefix=".sqlite-", dir=str(destination.parent))
            os.close(fd)
            deadline = time.monotonic() + 60

            def progress(_status: int, _remaining: int, _total: int) -> None:
                if time.monotonic() > deadline:
                    raise RecoveryError("SQLite export exceeded its time limit")

            try:
                with closing(sqlite3.connect(original.as_uri() + "?mode=ro", uri=True, timeout=10)) as input_db:
                    with closing(sqlite3.connect(temporary)) as output_db:
                        input_db.backup(output_db, pages=128, progress=progress, sleep=0.05)
                        output_db.execute("PRAGMA journal_mode=DELETE")
                        output_db.commit()
                shutil.copystat(str(destination), temporary)
                info = destination.stat()
                if os.stat(temporary).st_uid != info.st_uid or os.stat(temporary).st_gid != info.st_gid:
                    os.chown(temporary, info.st_uid, info.st_gid)
                os.replace(temporary, str(destination))
                for suffix in ("-wal", "-shm", "-journal"):
                    sidecar = Path(str(destination) + suffix)
                    if sidecar.exists() or sidecar.is_symlink():
                        sidecar.unlink()
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)


def drop_snapshot_views(work: Path, state: Dict[str, Any]) -> None:
    for name in ("home-volume", "root-volume"):
        target = work / name
        if target.exists():
            if target.is_symlink() or snapshot_uuid(target) != state.get("snapshots", {}).get(name):
                raise RecoveryError("Refusing to delete an unrecognized snapshot")
            run_command(["btrfs", "subvolume", "delete", str(target)], timeout=180)
            state["snapshots"].pop(name, None)
            private_json(work / "state.json", state)


def export_postgres(work: Path) -> List[str]:
    output = work / "exports" / "postgres"
    output.mkdir(parents=True, mode=0o700)
    names = run_command(["psql", "-w", "-U", "postgres", "-d", "postgres", "-A", "-t", "-c",
                         "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname;"]).splitlines()
    if not names or any(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]{0,62}", n) is None for n in names):
        raise RecoveryError("Database enumeration is empty or has an unsupported name")
    run_command(["pg_dumpall", "-w", "-U", "postgres", "--globals-only",
                 "--file", str(output / "globals.sql")], timeout=300)
    for name in names:
        target = output / (name + ".dump")
        run_command(["pg_dump", "-w", "-U", "postgres", "--format=custom", "--file", str(target),
                     "--dbname", name], timeout=900)
        if not run_command(["pg_restore", "--list", str(target)], timeout=120).strip():
            raise RecoveryError("Database dump catalog is empty")
    return names


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def prepare() -> Dict[str, Any]:
    plan = preflight()
    os.umask(0o077)
    if not WORK_ROOT.exists():
        WORK_ROOT.mkdir(mode=0o700)
    require_private_directory(WORK_ROOT)
    with (WORK_ROOT / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:12]
        work = WORK_ROOT / run_id
        work.mkdir(mode=0o700)
        state: Dict[str, Any] = {"schema": 1, "run_id": run_id, "ready": False, "snapshots": {},
                                 "started_at": datetime.now(timezone.utc).isoformat()}
        private_json(work / "state.json", state)
        try:
            private_json(work / "containers.json", {"containers": plan["containers"]})
            run_command(["btrfs", "filesystem", "sync", "/volume1"], timeout=120)
            for name, source in (("root-volume", "/volume1"), ("home-volume", "/volume1/homes")):
                target = work / name
                run_command(["btrfs", "subvolume", "snapshot", "-r", source, str(target)], timeout=180)
                state["snapshots"][name] = snapshot_uuid(target)
                private_json(work / "state.json", state)
                if run_command(["btrfs", "property", "get", "-ts", str(target), "ro"]).strip() != "ro=true":
                    raise RecoveryError("Snapshot is not read-only")
            members = []
            for text in plan["sources"]:
                source = Path(text)
                member = archive_member(source)
                target = work / member
                if member.startswith("system/"):
                    target.mkdir(parents=True, mode=0o700, exist_ok=True)
                    run_command(["rsync", "-aAX", "--numeric-ids", str(source) + "/", str(target) + "/"], timeout=300)
                    stabilize_sqlite(source, target)
                if not target.is_dir() or target.stat().st_ino == 2:
                    raise RecoveryError("A declared source is missing or is an empty subvolume placeholder")
                members.append(member)
            size_args = ["du", "-sb", *["--exclude=" + str(work / p) for p in EXCLUDES],
                         *[str(work / m) for m in members]]
            source_bytes = sum(int(line.split("\t", 1)[0]) for line in run_command(size_args, timeout=900).splitlines())
            if source_bytes > MAX_SOURCE_BYTES:
                raise RecoveryError("Recovery sources exceed the approved size budget")
            databases = export_postgres(work)
            validate_subvolume_coverage([Path(p) for p in plan["sources"]],
                                        run_command(["btrfs", "subvolume", "list", "/volume1"], timeout=120))
            current = inspect_containers()
            if container_identity(current) != plan["container_identity"]:
                raise RecoveryError("Container configuration changed while preparing the archive")
            manifest = {"schema": 1, "run_id": run_id, "started_at": state["started_at"],
                        "sources": plan["sources"], "source_bytes": source_bytes,
                        "archive_excludes": list(EXCLUDES), "postgres_exports": databases,
                        "snapshot_uuids": state["snapshots"],
                        "consistency": "Read-only per-subvolume crash-consistent views; logical databases exported separately",
                        "limitations": ["No original media or Drive internal repository", "No full-system or application restore proof"]}
            private_json(work / "manifest.json", manifest)
            if shutil.disk_usage("/volume1").free < MIN_FREE_BYTES + MAX_ARCHIVE_BYTES:
                raise RecoveryError("Insufficient remaining space before archive creation")
            run_command(tar_command(work, ["manifest.json", "containers.json", "exports", *members]), timeout=3600)
            archive = work / "recovery.tar"
            if archive.stat().st_size > MAX_ARCHIVE_BYTES:
                raise RecoveryError("Recovery archive exceeds its size budget")
            drop_snapshot_views(work, state)
            state.update({"ready": True, "archive_bytes": archive.stat().st_size, "archive_sha256": sha256(archive),
                          "completed_at": datetime.now(timezone.utc).isoformat()})
            private_json(work / "state.json", state)
            return {k: state[k] for k in ("run_id", "ready", "archive_bytes", "archive_sha256", "completed_at")}
        except BaseException as error:
            state["error_type"] = type(error).__name__
            private_json(work / "state.json", state)
            if isinstance(error, RecoveryError):
                raise RecoveryError("Run {} stopped: {}".format(run_id, error)) from error
            raise
        finally:
            drop_snapshot_views(work, state)


def load_run(run_id: str) -> Tuple[Path, Dict[str, Any]]:
    require_nas_root()
    validate_run_id(run_id)
    require_private_directory(WORK_ROOT)
    work = WORK_ROOT / run_id
    require_private_directory(work)
    path = work / "state.json"
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise RecoveryError("Recovery state file is not private")
    state = json.loads(path.read_text())
    if state.get("schema") != 1 or state.get("run_id") != run_id:
        raise RecoveryError("Recovery state does not match the requested run")
    return work, state


def stream(run_id: str) -> None:
    work, state = load_run(run_id)
    if not state.get("ready") or sys.stdout.isatty():
        raise RecoveryError("Only a complete archive can be streamed to a pipe")
    with (WORK_ROOT / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_SH)
        archive = work / "recovery.tar"
        if archive.is_symlink() or archive.stat().st_size != state["archive_bytes"]:
            raise RecoveryError("Recovery archive changed")
        with archive.open("rb") as source:
            shutil.copyfileobj(source, sys.stdout.buffer, length=1024 * 1024)


def cleanup(run_id: str) -> Dict[str, Any]:
    work, state = load_run(run_id)
    with (WORK_ROOT / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        drop_snapshot_views(work, state)
        shutil.rmtree(str(work))
    return {"run_id": run_id, "cleaned": True}


def handle_termination(_signum: int, _frame: Any) -> None:
    raise RecoveryError("Recovery operation was cancelled")


def main() -> None:
    for name in ("SIGTERM", "SIGINT", "SIGHUP"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), handle_termination)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "prepare", "stream", "cleanup"), nargs="?", default="plan")
    parser.add_argument("run_id", nargs="?")
    args = parser.parse_args()
    try:
        if args.action in ("stream", "cleanup"):
            if not args.run_id:
                raise RecoveryError("A recovery run identifier is required")
            if args.action == "stream":
                stream(args.run_id)
                return
            result = cleanup(args.run_id)
        elif args.action == "prepare":
            result = prepare()
        else:
            result = preflight()
            result.pop("containers")
            result["read_only"] = True
            result["max_source_bytes"] = MAX_SOURCE_BYTES
            result["archive_excludes"] = list(EXCLUDES)
        print(json.dumps(result, sort_keys=True))
    except (RecoveryError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        # Exception text from external programs and configuration data is not printed.
        print(json.dumps({"ok": False, "error_type": type(error).__name__,
                          "message": str(error) if isinstance(error, RecoveryError) else "Recovery operation failed"}), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
