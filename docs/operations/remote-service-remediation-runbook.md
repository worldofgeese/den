# Remote service remediation runbook

How-to for memoryless agents debugging/remediating **mother** (Synology Docker stack) and **loving-kypris** (Fedora CoreOS rootless Podman/Quadlets). Covers work validated 2026-06-19/20: Tdarr QSV pipeline, shared cache, Jellyfin/Postgres, Sonarr, Seerr, OpenClaw units.

## Before you touch anything

1. Read this file end-to-end.
2. On **loving-kypris**: `ssh loving-kypris` then read `~/openclaw-config/AGENTS.md` — quadlet deploy, secrets, volume safety.
3. Claim a Beads issue (`br update <id> --status in_progress`) before edits.
4. **Backup SQLite before any Tdarr DB mutation.**
5. Do not stop active transcodes unless stuck/deadlocked.
6. Do not fix transient provider/subscription failures (see [Out of scope](#out-of-scope)).

## Host quick reference

| Host | SSH | Init / containers | Config source |
|------|-----|-------------------|---------------|
| **mother** | `ssh mother` | Docker at `/usr/local/bin/docker` | `~/docker/docker-compose.yml` (symlink `/volume1/homes/taohansen/docker`) |
| **loving-kypris** | `ssh loving-kypris` | Rootless Podman + systemd user units | `~/openclaw-config/openclaw.quadlets` |

### mother paths

| Path | Purpose |
|------|---------|
| `/var/services/homes/taohansen/docker` | Stack root (same as `/volume1/homes/taohansen/docker`) |
| `/volume1/video`, `/var/services/video` | Media libraries |
| `/volume1/video/tdarr-cache` | Shared Tdarr cache (NFS); mounted in containers as `/temp` |
| `/var/services/homes/taohansen/docker/tdarr/server/Tdarr/DB2/SQL/database.db` | Tdarr SQLite DB |
| `/var/services/homes/taohansen/docker/tdarr/server/Tdarr/Plugins/Local/Tdarr_Plugin_local_H264_QSV_AAC_DirectPlay.js` | QSV transcode plugin |
| `http://127.0.0.1:8265` | Tdarr server API (scan, admin) |
| `http://127.0.0.1:8266` | Tdarr node API (`get-nodes`) |

### loving-kypris paths

| Path | Purpose |
|------|---------|
| `~/openclaw-config/` | Quadlet source of truth |
| `/var/mnt/video/tdarr-cache` | NFS mount of mother cache → container `/temp` |
| `/dev/dri` | QSV GPU passthrough for tdarr-node |
| `:18789` / `:18790` | OpenClaw gateway / socat-proxy |

### Deploy (loving-kypris only)

```bash
ssh loving-kypris 'cd ~/openclaw-config && podman quadlet install --replace openclaw.quadlets && systemctl --user daemon-reload'
```

Then restart affected units, e.g. `systemctl --user restart tdarr-node.service openclaw-gateway.service socat-proxy.service`.

---

## Safety rules

### mother

- Use `/usr/local/bin/docker`, not bare `docker` if PATH differs.
- Compose edits: backup first (`cp docker-compose.yml docker-compose.yml.bak.<tag>`).
- Synology: avoid destructive ops on shared volumes; no `rm` on backup paths per host policy.

### loving-kypris

- Rootless Podman — **no sudo**.
- **`openclaw.quadlets` is source of truth** (not legacy compose).
- **Never** `podman system prune --volumes`.
- **Never** `chown -R` inside volume data dirs.
- **Never** `rm -rf` storage symlink `~/.local/share/containers/storage`.
- `PublishPort=` alone insufficient for cross-host — firewalld zone required (see remote AGENTS).

---

## Tdarr — architecture

- **Server + InternalNode** on mother (Intel Celeron J3355, Apollo Lake, HD Graphics 500).
- **Remote node LovingKypris** (newer Intel; supports QSV low-power, but shared plugin disables `-low_power 1` for both nodes).
- Libraries: `movies_lib` → `/media/movies`, `tv_lib` → `/media/tv`.
- Plugin stack (7 plugins): local QSV DirectPlay → Migz image/audio → downmix → AAC → stream reorder → remove data streams.

### Node config (validated)

| Node | workerLimits (cpu / gpu) | gpuSelect | Notes |
|------|--------------------------|-----------|-------|
| InternalNode | 1 / 1 (session also saw 2 active) | **`qsv`** | Apollo Lake; `/dev/dri` in tdarr container |
| LovingKypris | 3 / 3 | **`qsv`** | `GroupAdd=video`, `/dev/dri`, cache bind below |

**Critical:** `gpuSelect` must be **`qsv`**, not `all` or `-`. Tdarr bug: `all` breaks `isGPUCommandNodeCanDo` → `requireGPU` / wontProcess loops.

**LovingKypris tdarr-node quadlet binds (commit `bdca75f`):**

- `/var/mnt/video/tdarr-cache:/temp`
- `/dev/dri:/dev/dri`
- `GroupAdd=video`

**mother tdarr container:** mount `/volume1/video/tdarr-cache:/temp`. Library cache for `movies_lib` + `tv_lib` = **`/temp`** (not `.`).

---

## Tdarr — diagnostics

### Health snapshot

```bash
ssh mother 'curl -s http://127.0.0.1:8266/api/v2/get-nodes | python3 -c "
import sys,json
for n in json.load(sys.stdin).values():
  print(n[\"nodeName\"], \"limits\", n[\"workerLimits\"], \"queues\", n[\"queueLengths\"], \"workers\", len(n.get(\"workers\",{})))
"'
```

```bash
ssh mother '/usr/local/bin/docker ps --filter name=tdarr --format "{{.Names}} {{.Status}}"'
ssh loving-kypris 'systemctl --user is-active tdarr-node.service; ls -la /var/mnt/video/tdarr-cache | head'
```

### Cache RW proof (both nodes must see same files)

```bash
ssh mother 'test -w /volume1/video/tdarr-cache && echo RW_OK || echo RW_FAIL'
ssh loving-kypris 'test -w /var/mnt/video/tdarr-cache && echo RW_OK || echo RW_FAIL'
ssh mother 'ls /volume1/video/tdarr-cache | wc -l'
```

### SQLite decision breakdown

```bash
ssh mother 'cd ~/docker/tdarr/server/Tdarr/DB2/SQL && sqlite3 database.db "
SELECT json_extract(json_data, \"\$.TranscodeDecisionMaker\") AS d, COUNT(*) FROM filejsondb GROUP BY d ORDER BY COUNT(*) DESC LIMIT 10;
"'
```

```bash
ssh mother 'cd ~/docker/tdarr/server/Tdarr/DB2/SQL && sqlite3 database.db "
SELECT json_extract(json_data, \"\$.TranscodeDecisionMaker\") AS d, COUNT(*)
FROM filejsondb WHERE json_extract(json_data, \"\$.video_codec_name\") = \"hevc\" GROUP BY d;
"'
```

### Bad log grep patterns

Run on mother tdarr server logs and loving-kypris tdarr-node logs:

```bash
# 501 cache handoff — broken shared /temp
grep -E '501 POST /api/v2/file/download' 

# QSV / plugin failures
grep -E 'requireGPU|wontProcess|TypeError|Error reinitializing filters|Function not implemented|Conversion failed|NO OUTPUT FILE'

# Worker / GPU
grep -E 'h264_qsv|low_power|vpp_qsv|gpuSelect'

# Report backpressure (usually non-fatal if transcodes succeed)
grep -E 'Failed to log job report: Request dropped due to queue overflow'

# NFS faststart race after long transcode
grep -E 'Unable to re-open /temp|moov atom not found|faststart'
```

---

## Tdarr — failure modes and remediation

### 1. `501 POST /api/v2/file/download`

**Symptom:** QSV stage succeeds; downstream plugins fail; staged rows pile up; no `transcodeSuccess`.

**Cause:** Cache path drift — library cache `.` or empty `/temp`, nodes not sharing same NFS workdirs.

**Fix:**

1. Backup DB: `cp database.db database.db.cachefix-$(date -u +%Y%m%d-%H%M%S).bak`
2. Set library cache `/temp` for both libraries (Tdarr UI or DB).
3. Ensure mounts:
   - mother: `/volume1/video/tdarr-cache:/temp`
   - loving-kypris: `/var/mnt/video/tdarr-cache:/temp`
4. Recreate/restart containers; verify both nodes list same paths under `/temp`.
5. Clear stale `stagedjsondb` if capped at 100 with old workdirs.
6. Reset `Transcode error` rows → empty or `Queued` (see below).

**Proof:** zero `501` lines after fix timestamp; at least one `transcodeSuccess` in job reports.

### 2. `TranscodeDecisionMaker: Transcode error` (bulk idle)

**Symptom:** Thousands of HEVC files marked error; queues idle despite workers up.

**Cause:** Prior QSV/plugin failures poisoned file rows.

**Fix (after plugin/cache fixed):**

```bash
ssh mother 'cd ~/docker/tdarr/server/Tdarr/DB2/SQL && \
  cp database.db database.db.reset-$(date -u +%Y%m%d-%H%M%S).bak && \
  sqlite3 database.db "UPDATE filejsondb SET json_data = json_set(json_data, \"\$.TranscodeDecisionMaker\", \"\") WHERE json_extract(json_data, \"\$.TranscodeDecisionMaker\") = \"Transcode error\";" && \
  sqlite3 database.db "DELETE FROM stagedjsondb;"'
```

Then trigger rescan (see [scanFresh API](#scanfresh-api)).

### 3. Staged deadlock (staged ≈ 100, queue flat)

**Symptom:** `stagedjsondb` full; processing stalls.

**Fix:** Backup DB → `DELETE FROM stagedjsondb;` → `scanFresh` → confirm workers pull new jobs.

### 4. `requireGPU` / wontProcess

**Symptom:** Logs show `Won't process: requireGPU`.

**Cause:** Plugin preset uses QSV but node `gpuSelect` wrong, or GPU workers unavailable.

**Fix:** Set node `gpuSelect` to **`qsv`** on both nodes; confirm `transcodegpu` workers > 0 and `/dev/dri` present.

### 5. QSV encode failures (Apollo Lake / 10-bit HEVC)

**Symptom:** `Error reinitializing filters`, `-38 Function not implemented`, `-22 Invalid argument`.

**Root causes in old plugin:**

| Bug | Fix |
|-----|-----|
| Trailing comma: `-hwaccel_output_format qsv,` | Remove comma |
| 10-bit HEVC → h264_qsv | Add `-vf vpp_qsv=format=nv12` in filter chain |
| `-low_power 1` on Apollo Lake | **Do not use** on mother (J3355) |
| Shared plugin | Disables low_power globally (LovingKypris capable but plugin sets off) |

**Plugin path:** `/var/services/homes/taohansen/docker/tdarr/server/Tdarr/Plugins/Local/Tdarr_Plugin_local_H264_QSV_AAC_DirectPlay.js`

After plugin edit: restart tdarr server/node containers; watch for `h264_qsv` in worker CLI without filter errors.

### 6. NFS faststart / duplicate-worker transcode errors

**Symptom:** Long QSV job completes then fails on `Unable to re-open /temp/...mp4` during moov shift; same title on both nodes.

**Cause:** Duplicate concurrent workers on shared cache file (race), not cache split.

**Fix:** Backup DB → reset affected row `TranscodeDecisionMaker` to `Queued` → remove stale workdir under `/temp` → let single worker retry. Do not treat as 501/cache misconfig if 501 grep clean.

### 7. Job report queue overflow

**Symptom:** `Failed to log job report: Request dropped due to queue overflow` (often loving-kypris).

**Scope:** Transcoding may still succeed. On mother, job report history was **854 MiB / 10240 MiB** — within limit after tuning. Treat as **monitor**, not stop-the-line, unless transcodes fail.

---

## scanFresh API

**Wrong:** `mode: scan` or missing `dbID` → HTTP 400.

**Correct:** POST to server port **8265**:

```python
import json, urllib.request
body = json.dumps({
  "data": {
    "scanConfig": {
      "dbID": "movies_lib",      # or tv_lib
      "mode": "scanFresh",
      "arrayOrPath": "/media/movies"  # or /media/tv
    }
  }
}).encode()
req = urllib.request.Request(
  "http://127.0.0.1:8265/api/v2/scan-files",
  data=body,
  headers={"Content-Type": "application/json"},
  method="POST",
)
urllib.request.urlopen(req, timeout=10)
```

Allowed modes: `scanFresh`, `scanFindNew`, `scanFolderWatcher`.

---

## Tdarr — proof gates

Before closing Tdarr work, collect evidence on **mother**:

```bash
# Nodes registered, GPU workers active
curl -s http://127.0.0.1:8266/api/v2/get-nodes | python3 -m json.tool | head -80

# Zero bad patterns since fix time (adjust timestamp)
grep -E '501 POST|TypeError|Conversion failed' ~/docker/tdarr/server/logs/*.txt | tail -20

# At least one success
grep -l transcodeSuccess ~/docker/tdarr/server/Tdarr/DB2/JobReports/*/*transcode* 2>/dev/null | tail -3
```

Write proof artifact, e.g. `/var/services/homes/taohansen/docker/tdarr/cachefix-proof-YYYYMMDD.txt` or `/tmp/tdarr-monitor-ui5-*.log`.

### Session proof artifacts (reference)

| Artifact | Session |
|----------|---------|
| `database.db.qsvfix-20260619T225831Z.bak` | QSV gpuSelect fix |
| `qsvfix-proof-20260620-013532.txt` | QSV validation |
| `/tmp/tdarr-qsvfix-proof-20260619T231727Z` | QSV proof |
| `database.db.cachefix-20260620-092653.bak` | Shared cache fix |
| `cachefix-proof-20260620.txt` | Cache validation |
| `database.db.backup-ui5-*` | Monitor interventions |
| `/tmp/tdarr-monitor-ui5-20260620T074617Z.log` | 65min monitor log |

---

## mother — Jellyfin / Postgres

**Symptom:** Jellyfin `Command timed out`, Postgres `broken pipe`, high CPU.

**Validated tuning (2026-06-20):**

- Jellyfin env: `POSTGRES_COMMAND_TIMEOUT=300` (was 120).
- Postgres: `work_mem=16MB`, `maintenance_work_mem=256MB`, `effective_cache_size=2GB`.
- Run `VACUUM ANALYZE` on jellyfin DB after tuning.

**Verify:**

```bash
ssh mother '/usr/local/bin/docker inspect jellyfin --format "{{range .Config.Env}}{{println .}}{{end}}" | grep POSTGRES_COMMAND_TIMEOUT'
ssh mother '/usr/local/bin/docker ps --filter name=jellyfin --filter name=jellyfin-db --format "{{.Names}} {{.Status}}"'
```

Bursty timeouts after restart may be transient — monitor 24h before deeper changes.

---

## mother — Sonarr permissions / SQLite

**Symptom:** `SQLite Error database is locked`, cannot create `.nfo` in Community paths.

**Root cause (2026-06-20):** Community Season 3–6 dirs `root:root 755` after Tdarr activity; Sonarr PUID 1038 blocked.

**Fix:**

```bash
ssh mother 'sudo chown -R sonarr:media "/volume1/video/tv/Community/Season 3" "/volume1/video/tv/Community/Season 4" "/volume1/video/tv/Community/Season 5" "/volume1/video/tv/Community/Season 6"'
ssh mother 'sudo chmod -R 775 ...same paths...'
ssh mother '/usr/local/bin/docker restart sonarr'
```

**Verify:** `docker exec sonarr touch` + `rm` test file in Season 4 → `WRITE_OK`.

---

## mother — Seerr logging hang

**Symptom:** `docker logs seerr` hangs 85s+.

**Cause:** Synology default `db` log driver.

**Fix:** In compose, seerr service:

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```

Recreate container. **Verify:** `docker logs --tail 5 seerr` returns in <5s.

---

## loving-kypris — failed user units (2026-06-20 fixes)

| Unit | Issue | Remediation |
|------|-------|-------------|
| `podman-auto-update.service` | Exit 125 pinging registry for **local** image | `cataphract` quadlet: `AutoUpdate=local`; restart cataphract |
| `podman-cleanup.service` | Exit 125 image in use | User unit: tolerate prune 125 with `\|\| true` in ExecStart |
| `socat-proxy.service` | Failed after gateway SIGTERM | Restart `openclaw-gateway.service` then socat-proxy |
| `openclaw-gateway` | OpenAI embedding 429 spam | Set `memory.backend=qmd` in openclaw data volume (repo already qmd) |

**Verify:**

```bash
ssh loving-kypris 'systemctl --user --failed; systemctl --user is-active socat-proxy.service openclaw-gateway.service cataphract.service'
ssh loving-kypris 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18790/'
ssh loving-kypris 'journalctl --user -u openclaw-gateway.service --since "10 min ago" | grep -i embedding | tail'
```

**IaC note:** `podman-cleanup.{service,timer}` added under `openclaw-config/systemd/user/` — install per remote AGENTS.

---

## Out of scope (do not burn cycles)

| Signal | Host | Action |
|--------|------|--------|
| NZBGet / Tweaknews auth storm | mother | Transient provider — skip |
| Bazarr subtitle subscription limit | mother | Subscription — skip |
| OpenAI quota / Codex / copilot provider errors | loving-kypris | Provider billing/config — skip unless user requests |
| Copyparty self-signed TLS `CN=copyparty-insecure` | loving-kypris | Behind cloudflared — skip |
| Podman TCP without TLS warning | loving-kypris | Internal `DOCKER_HOST=tcp://podman-in-podman:2375` — expected |
| Jellyfin timeout burst | mother | May be post-restart transient — monitor |
| Tdarr job-report overflow under load | loving-kypris | Monitor if transcodes OK; see bead `home-manager-dkf` |

---

## SQLite backup template

Always before Tdarr DB writes:

```bash
ssh mother 'cd ~/docker/tdarr/server/Tdarr/DB2/SQL && cp -a database.db database.db.$(date -u +%Y%m%dT%H%M%SZ).bak && ls -la database.db*.bak | tail -3'
```

---

## Related beads

| ID | Topic |
|----|-------|
| `home-manager-5gk` | QSV workers both nodes |
| `home-manager-exk` | Shared NFS cache / 501 fix |
| `home-manager-ui5` | 65min Tdarr monitor |
| `home-manager-bji` | Sonarr/Jellyfin/Seerr + LovingKypris units |
| `home-manager-7la` | Persist gpuSelect=qsv in IaC (open) |
| `home-manager-dkf` | Job report overflow tuning (open) |

---

## Agent handoff checklist

- [ ] Read remote AGENTS on loving-kypris before edits there
- [ ] DB backup before Tdarr SQLite changes
- [ ] Proof artifact written with timestamps
- [ ] Bad log grep shows zero new errors since fix
- [ ] `get-nodes` shows both nodes, QSV workers active
- [ ] Durable config in IaC (`docker-compose.yml` / `openclaw.quadlets`) — not only live hotfix
- [ ] Bead updated/closed with proof paths
