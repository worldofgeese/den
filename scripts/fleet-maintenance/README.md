# Mother recovery archive

`mother_recovery.py` prepares the limited NAS recovery set for an encrypted backup on loving-kypris. It does not install DSM, SRM, firmware, or Swamp. Work and deployment evidence belong to `home-manager-zym`.

The script supports the Python 3.8 runtime that ships on mother. It uses the existing Btrfs, GNU tar, rsync, SQLite and PostgreSQL tools. It has no third-party Python dependency.

## Scope and source consistency

The archive includes the approved container state directories, DSM configuration, native package state and home directories, Tang keys, and PostgreSQL data and exports. It excludes the Drive internal repository, original media, downloads, Docker images, and Container Manager's `all_shares` views.

The script takes separate read-only Btrfs snapshots of the volume root and the `homes` subvolume. It rejects unsupported nested subvolumes instead of archiving empty placeholders. These views are crash-consistent per subvolume, not one atomic snapshot of the entire NAS.

System-directory copies use rsync with ownership, ACL and extended-attribute preservation. SQLite databases in these live system copies use the online backup API. PostgreSQL logical exports provide a second recovery format, with a separate transaction snapshot for each database.

The temporary source snapshots are deleted after tar completes and during normal failure cleanup. They are not a long-term snapshot policy for media or the entire NAS.

## Commands

The default command only checks prerequisites and prints a plan:

```bash
sudo python3 mother_recovery.py plan
```

The plan does not create snapshots, archives or directories. It checks RAID health, tools, source coverage, subvolume layout and a conservative free-space reserve.

After review of the plan, create the source archive:

```bash
sudo python3 mother_recovery.py prepare
```

This command creates a private run directory under `/volume1/@fleet-recovery`. It returns a JSON receipt with the run identifier, archive size and SHA-256. It marks the run ready only after archive creation and source-snapshot cleanup succeed.

The run contains a plaintext archive. Keep the directory private. Transfer the archive over SSH into a private staging directory on loving-kypris, then back it up through Zerobyte.

`stream RUN_ID` writes binary archive data to stdout. Never run it through a tool that displays stdout as text. The caller must send stdout directly to a private file, compare the receipt's size and SHA-256, and publish the staged file only after both match.

After the encrypted backup and restore checks pass, delete the owned temporary run:

```bash
sudo python3 mother_recovery.py cleanup RUN_ID
```

Use the exact run identifier from the receipt. Cleanup only accepts a private run with matching ownership and state. It verifies any remaining snapshot UUID before deleting that snapshot. It never deletes original source directories.

## Failure rules

A missing source, unexpected container mount, unsupported subvolume, degraded RAID, failed export, or insufficient space stops the run. External program output is not printed because it can contain sensitive data.

Do not disable a gate to make a backup appear successful. A failed run can retain private diagnostic or archive files. Review its state and use scoped cleanup after the failure is understood.

SIGTERM, SIGINT and SIGHUP enter the normal exception cleanup path. An uncatchable process kill or power failure can still leave temporary views. Their presence requires a cleanup check before another maintenance action.

## Encryption and later backups

Zerobyte 0.44 uses the organization recovery key for a new repository. Its `customPassword` field only applies to an imported repository. An accepted field does not prove which key encrypts the repository.

Export the existing organization recovery key through the authenticated `/api/v1/system/restic-password` endpoint. Keep a separate recovery copy in the Mac Keychain. Open the repository with that key through native Restic before you delete plaintext copies. Do not rotate encryption to correct an unused password field.

Keep a new recurring job disabled until a workflow prepares and checks fresh source data before each backup. A successful backup of an old archive does not prove current NAS recovery coverage. The helper does not supply that workflow or its scheduler.

Swamp supports an API key through `SWAMP_API_KEY_FILE`. Keep that file outside the repository with mode `0600`. Do not pass an API key as the password for `swamp auth login`.

## Verification

Run the focused boundary tests from the repository root:

```bash
python3 -m unittest discover -s scripts/fleet-maintenance -p 'test_*.py'
```

The source receipt is not proof of an encrypted backup. The consumer must verify Zerobyte's snapshot result, restore the archive, compare its hash, and inspect the restored database artifacts.

Do not restore to original NAS paths during a verification drill. Use a private temporary destination. These checks do not prove a full NAS rebuild or a supported DSM downgrade.

## Checkpoint runner status

`mother_checkpoint.py` runs on loving-kypris. It combines source preparation, bounded transfer, a manual Zerobyte backup, native Restic restoration, and scoped cleanup. It has no firmware action and no automatic retry of an incomplete attempt.

The private configuration requires `repository_id`, `backup_id`, `binding_sha256`, `data_root`, `state_root`, `api_key_file`, and `restic_password_file`. Keep that file and both secret files outside git with mode `0600`. The binding hash records the approved backup configuration, including its source, repository, exclusions, and disabled native schedule. Mutable health and result fields do not change the hash.

Without `--execute`, the runner only checks local prerequisites and the Zerobyte binding. That result does not prove NAS health. With `--execute`, it prepares a fresh source and requires a new successful snapshot with the correct job tag. An old success, a partial backup, an active task, or a stale receipt cannot pass.

The runner keeps a private journal in `state_root`. If a run fails, inspect that journal before another attempt. It does not replay an uncertain backup request or delete an unknown temporary source. Restic restoration has the same byte limit as the source archive.

## Deployment on loving-kypris

The deployed copies live outside git. Copy `mother_checkpoint.py`, `mother_recovery.py`, `checkpoint-heartbeat.sh`, and this README to `~/.local/share/fleet-maintenance/checkpoint/`. The runner sends `mother_recovery.py` from that folder to mother.

Restic 0.19.1 is at `~/.local/share/fleet-maintenance/bin/restic`. Install it from the official GitHub release. Make sure that its SHA-256 matches both `SHA256SUMS` and the GitHub asset digest.

The private files are in `~/.config/fleet-maintenance/`, each with mode `0600`:

- `mother-checkpoint.json` is the runner configuration.
- `zerobyte-api-key` is the dedicated `Swamp Mother Recovery` key, without expiry. The Mac Keychain service `zerobyte-api-swamp` holds a second copy.
- `restic-password` is the organization recovery key. The Mac Keychain service `zerobyte-restic-organization` holds a second copy.

The Zerobyte key has the access of the user that created it, in the whole organization. Zerobyte has no scope for one repository. The runner limits itself to the bound job and repository.

`swamp/` holds the Swamp model and workflow. Copy them into `~/.local/share/fleet-maintenance/swamp`. `systemd/` holds the user service and timer. The timer starts the service at 00:30 UTC each day. The service runs `swamp workflow run`, and Swamp records each run.

The design does not use `swamp serve`. Its scheduler needs an always-on WebSocket server. Without token authentication, any local client could run `command/shell` behaviors, including a container on the host network.

After a verified run, `checkpoint-heartbeat.sh` connects to paphos with `~/.ssh/fleet-heartbeat-paphos`. On paphos, that key can only write the current time to `/var/lib/fleet-heartbeat/mother-checkpoint`. The hourly paphos health check sends a Telegram alert when that time is older than 36 hours. The check still runs when loving-kypris is down.

The first two live runs on 2026-11-01 produced the verified snapshots `88b1a016` and `02562414`. The second run used the Swamp service path.

The Restic test repeats a full data read each day. If the repository grows, change it to a sampled read and keep a periodic full read.
