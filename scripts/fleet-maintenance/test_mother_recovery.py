import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List

import mother_recovery as recovery


class RecoveryBoundaryTests(unittest.TestCase):
    def test_run_id_rejects_paths_and_empty_values(self) -> None:
        for value in ("", ".", "..", "../source", "/volume1", "20261101T120000Z-../bad"):
            with self.subTest(value=value), self.assertRaises(recovery.RecoveryError):
                recovery.validate_run_id(value)
        self.assertEqual(
            recovery.validate_run_id("20261101T120000Z-0123456789ab"),
            "20261101T120000Z-0123456789ab",
        )

    def test_source_allowlist_excludes_bulk_and_unknown_paths(self) -> None:
        for value in (
            "/", "/volume1", "/volume1/homes", "/volume1/video",
            "/volume1/@synologydrive/@sync/repo",
            "/volume1/@appdata/ContainerManager/all_shares",
            "/volume1/homes/taohansen/downloads",
            "/volume1/homes/taohansen/docker",
            "/etc/../root",
        ):
            with self.subTest(value=value), self.assertRaises(recovery.RecoveryError):
                recovery.validate_source(Path(value))

    def test_known_recovery_sources_are_allowed(self) -> None:
        for value in (
            "/etc", "/usr/syno/etc", "/volume1/@database/pgsql",
            "/volume1/@synologydrive", "/volume1/@tang-db",
            "/volume1/@appdata/SynologyPhotos",
            "/usr/local/packages/@appdata/OAuthService",
            "/volume1/@apphome/SynologyPhotos", "/var/packages/Example/var",
            "/volume1/homes/taohansen/docker/sonarr/config",
        ):
            with self.subTest(value=value):
                recovery.validate_source(Path(value))

    def test_members_keep_distinct_subvolume_and_system_roots(self) -> None:
        self.assertEqual(
            recovery.archive_member(Path("/volume1/homes/taohansen/docker/sonarr/config")),
            "home-volume/taohansen/docker/sonarr/config",
        )
        self.assertEqual(
            recovery.archive_member(Path("/volume1/@database/pgsql")),
            "root-volume/@database/pgsql",
        )
        self.assertEqual(recovery.archive_member(Path("/etc")), "system/etc")

    def test_tar_preserves_metadata_and_excludes_internal_repository(self) -> None:
        members = ["root-volume/@synologydrive", "system/etc"]
        args = recovery.tar_command(Path("/private/run"), members)
        self.assertIn("--acls", args)
        self.assertIn("--xattrs", args)
        self.assertIn("--numeric-owner", args)
        self.assertIn("--sparse", args)
        self.assertIn("--exclude=root-volume/@synologydrive/@sync/repo", args)
        self.assertIn("--exclude=root-volume/@appdata/ContainerManager/all_shares", args)
        self.assertEqual(args[-3:], ["--", *members])
        self.assertNotIn("--dereference", args)
        self.assertNotIn("--ignore-failed-read", args)

    def test_raid_must_be_present_and_healthy(self) -> None:
        recovery.validate_raid("md0 : active raid1\n  100 blocks [2/2] [UU]\n")
        for text in ("", "md0 : active raid1\n 100 blocks [2/1] [U_]\n"):
            with self.assertRaises(recovery.RecoveryError):
                recovery.validate_raid(text)

    def test_nested_subvolumes_cannot_disappear_from_a_parent_snapshot(self) -> None:
        sources = [Path("/volume1/homes/taohansen/docker/sonarr/config")]
        normal = "ID 47844 gen 1 top level 257 path @syno/homes\n"
        recovery.validate_subvolume_coverage(sources, normal)
        recovery.validate_subvolume_coverage(sources, normal.replace("@syno/homes", "homes"))
        nested = normal + "ID 50000 gen 1 top level 47844 path @syno/homes/taohansen/docker/sonarr/config/data\n"
        with self.assertRaises(recovery.RecoveryError):
            recovery.validate_subvolume_coverage(sources, nested)
        with self.assertRaises(recovery.RecoveryError):
            recovery.validate_subvolume_coverage(sources, "unrecognized listing")
        ancestor = normal + "ID 50000 gen 1 top level 257 path @database\n"
        with self.assertRaises(recovery.RecoveryError):
            recovery.validate_subvolume_coverage([Path("/volume1/@database/pgsql")], ancestor)

    def test_package_state_includes_real_var_and_home_directories(self) -> None:
        with tempfile.TemporaryDirectory() as base:
            root = Path(base).resolve()
            package = root / "Example"
            (package / "var").mkdir(parents=True)
            (package / "home").mkdir()
            self.assertEqual(set(recovery.package_sources(root)), {package / "var", package / "home"})

    def test_container_mount_drift_is_not_silently_ignored(self) -> None:
        containers: List[Dict[str, Any]] = [
            {"Name": "/" + name, "Mounts": [
                {"Destination": destination, "Source": source}
                for destination, source in mounts.items()
            ]}
            for name, mounts in recovery.EXPECTED_MOUNTS.items()
        ]
        recovery.validate_containers(containers)
        containers[0]["Mounts"].append({"Destination": "/new-database", "Source": "/volume1/new-database"})
        with self.assertRaises(recovery.RecoveryError):
            recovery.validate_containers(containers)
        containers[0]["Mounts"].pop()
        containers[0]["Mounts"][0]["Source"] = "/volume1/homes"
        with self.assertRaises(recovery.RecoveryError):
            recovery.validate_containers(containers)
        with self.assertRaises(recovery.RecoveryError):
            recovery.validate_containers([])

    def test_fingerprint_ignores_only_unordered_mount_list_order(self) -> None:
        from copy import deepcopy

        original: List[Dict[str, Any]] = [{"Name": "/example", "Id": "same-id", "Image": "same-image", "Config": {
            "Env": ["A=1", "A=2"], "Cmd": ["one", "two"], "Entrypoint": ["entry", "flag"],
        }, "Mounts": [
            {"Type": "bind", "Source": "/one", "Destination": "/config", "Mode": "rw", "RW": True, "Propagation": "rprivate"},
            {"Type": "bind", "Source": "/two", "Destination": "/cache", "Mode": "ro", "RW": False, "Propagation": "rprivate"},
        ]}]
        fingerprint = recovery.container_identity(original)
        reordered = deepcopy(original)
        reordered[0]["Mounts"].reverse()
        self.assertEqual(fingerprint, recovery.container_identity(reordered))
        self.assertEqual(original[0]["Mounts"][0]["Source"], "/one")
        for field, value in (("Source", "/changed"), ("RW", False), ("Propagation", "rshared")):
            changed = deepcopy(original)
            changed[0]["Mounts"][0][field] = value
            self.assertNotEqual(fingerprint, recovery.container_identity(changed))
        for field in ("Env", "Cmd", "Entrypoint"):
            changed = deepcopy(original)
            changed[0]["Config"][field].reverse()
            self.assertNotEqual(fingerprint, recovery.container_identity(changed))

    def test_live_sqlite_copy_is_replaced_by_a_consistent_database(self) -> None:
        import shutil
        import sqlite3

        with tempfile.TemporaryDirectory() as base:
            source = Path(base) / "source"
            target = Path(base) / "target"
            source.mkdir()
            target.mkdir()
            with sqlite3.connect(str(source / "state.db")) as database:
                database.execute("PRAGMA journal_mode=WAL")
                database.execute("CREATE TABLE sample (value INTEGER)")
                database.execute("INSERT INTO sample VALUES (1)")
                database.commit()
                for path in source.iterdir():
                    shutil.copy2(str(path), str(target / path.name))
                database.execute("INSERT INTO sample VALUES (2)")
                database.commit()
                recovery.stabilize_sqlite(source, target)
                with sqlite3.connect(str(target / "state.db")) as restored:
                    self.assertEqual(restored.execute("PRAGMA quick_check").fetchone()[0], "ok")
                    self.assertEqual(restored.execute("SELECT count(*) FROM sample").fetchone()[0], 2)
            self.assertFalse((target / "state.db-wal").exists())
            self.assertFalse((target / "state.db-shm").exists())

    def test_termination_uses_the_cleanup_exception_path(self) -> None:
        with self.assertRaises(recovery.RecoveryError):
            recovery.handle_termination(15, None)

    def test_private_work_directory_cannot_be_a_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as base:
            path = Path(base) / "real"
            path.mkdir(mode=0o700)
            link = Path(base) / "link"
            link.symlink_to(path, target_is_directory=True)
            recovery.require_private_directory(path)
            with self.assertRaises(recovery.RecoveryError):
                recovery.require_private_directory(link)
            path.chmod(0o755)
            with self.assertRaises(recovery.RecoveryError):
                recovery.require_private_directory(path)


if __name__ == "__main__":
    unittest.main()
