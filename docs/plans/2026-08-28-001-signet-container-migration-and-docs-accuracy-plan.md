---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
type: refactor
created: 2026-08-28
---

# Signet container migration, docs accuracy pass, and upstream reports

## Goal Capsule

**Objective:** An engineer on this machine keeps cross-session agent memory that answers with
semantic recall, survives a machine restart without hand-holding, and is described accurately enough
in the shared LEGO documentation that a colleague adopting the stack gets what the page promises.

**Means:** Replace the native Signet install with a containerised daemon (KTD1), correct the two
LEGO docs pages against their sources (KTD5), and report the two remaining upstream defects
(KTD6).

**Authority hierarchy:** the live daemon and the tools' own repositories outrank this plan; this plan
outranks prior session notes; prior session notes outrank recollection.

**Stop conditions:**

- `DEC-1` unanswered — U1-U5 must not start (see Open Questions). U6-U11 are unaffected.
- A migration step is about to write to `~/.agents` without a restore-verified backup.
- Post-migration recall reports `keyword`, memory count drops below 81, or the 4-repo source is
  absent.
- `just deploy-darwin` fails for a reason outside the Signet change.
- A docs claim cannot be sourced.

**Execution profile:** long-running, autonomous, no attempt ceiling.

**Tail ownership:** this plan owns through merge of both PRs and the filed issue; it does not own
upstream triage outcomes.

## Product Contract

### Summary

Signet on M-02877 currently runs as a compiled native binary supervised by a launchd LaunchAgent,
with two environment variables that are load-bearing for semantic recall and no error surface when
they are missing. The same machine already runs three containerised services. This plan moves Signet
into a container, removes the native path, and brings the two LEGO documentation pages into
agreement with the tools they describe — including Caveman's v2 release, which turned it from a
prompt-side skill into a proxy with a published benchmark.

### Problem Frame

Three problems, one root cause each:

1. **The native install is fragile in a way that fails silently.** Signet regenerates its own
   LaunchAgent on every auto-update and drops environment it did not author. Twice today that
   produced a daemon that looked healthy while recall had degraded to keyword-only, and once a
   crash-loop that ran unnoticed for 18 days (`exit 78`, 2146 restarts) because the plist carried a
   reaped `signet update` temp dir as its working directory.
2. **The docs describe a stack that no longer exists.** A three-persona review found 31 findings, 24
   unique, three of them unanimous P0s. Every one fails silently: a reader follows the page, gets
   less compression or less recall than promised, and sees no error.
3. **Two upstream defects are unreported**, and a third was filed today. The unreported one breaks
   every harness that spawns `signet-mcp`.

### Requirements

- **R1** — The Signet daemon runs from a container image, published on host loopback port 3850, and
  is restarted automatically by its runtime after a host or runtime restart.
- **R2** — Memory data survives the migration: recall answers in `hybrid` mode, memory count is at
  least 81, and the 4-repo GitHub source is still registered and indexed.
- **R3** — A restore-verified backup of the workspace exists before any migration step writes to it.
- **R4** — The native install is absent afterwards: no compiled binary on `PATH`, no npm-installed
  package, no `ai.signet.daemon*` LaunchAgent, and no `signet-daemon` block in the nix-darwin
  aspect. Whatever CLI entry point remains is the one `DEC-1` selects.
- **R5** — Host integrations that depend on Signet keep working, or are explicitly retired with the
  loss stated: Claude Code hooks, the Oh My Pi extension, transcript capture, the encrypted secret
  store, GraphIQ code retrieval, and dreaming's route through the loopback gateway shim.
- **R6** — `docs/guides/setup-token-saving-toolchain.md` no longer claims Signet distils each
  session, no longer carries extraction-era troubleshooting rows, and documents the container
  install path.
- **R7** — Both LEGO pages describe Caveman v2 accurately: a local proxy plus the MIT skill, the
  pinned 54-run benchmark in place of the unsourced output-token figure, pixel mode and the
  content-addressed store, the BSL-1.1/MIT licence split, and Caveman on the wire in the
  request-path diagram.
- **R8** — PR #85 is merged; the second docs PR is reviewed by the same three personas and merged.
- **R9** — The `signet-mcp` / `better-sqlite3` defect is filed upstream with a reproduction.
- **R10** — Every unit below exists as a bead with acceptance criteria.

### Key Decisions

- **Container deployment fully replaces the native install** (session-settled: user-directed —
  chosen over keeping the native binary as a fallback: one supervision path, no drift between two
  daemons). Governs R1, R4.
- **No attempt ceiling; halt only on the named stop conditions** (session-settled: user-directed —
  chosen over a 40-attempt per-track cap: the destructive step is guarded by explicit conditions
  rather than by a retry budget). Governs the Goal Capsule.
- **The agent runs `just deploy-darwin` and merges PR #85** (session-settled: user-directed — chosen
  over reserving both for the human).
- **Docs go container-first and recommend the Caveman v2 proxy** (session-settled: user-approved —
  chosen over documenting both install paths with native as the reader default). Governs R6, R7.

### Success Criteria

- A container runtime restart, followed by no manual action, leaves recall answering in `hybrid`.
- A colleague following the setup guide's Signet section reaches a running daemon without hitting an
  instruction that contradicts the tool.
- No claim in either page is unsourced after the pass; figures name their benchmark.

### Scope Boundaries

In scope: this host's Signet deployment, the two LEGO pages, the nix-darwin aspect for this host,
beads, and the upstream report.

Deferred: migrating headroom, phoenix, or local-model-proxy off Apple `container`; adopting the
Caveman v2 proxy on this machine (the docs recommend it; installing it is separate work); a
provenance convention for the savings tables.

Outside this work's identity: other hosts and their Guix files; the pre-existing `oracleHost`
evaluation failure; upstream triage of the filed issues.

### Outstanding Questions

- **DEC-1 (blocking, owns U1-U5)** — see Open Questions below.

### Sources

- `deploy/docker/compose.yml`, `deploy/docker/README.md`, `deploy/docker/entrypoint.sh` in the
  Signet source checkout at `~/.agents/signetai` (v0.214.22) — the first-party container shape.
- `https://signetai.sh/skill.md` — the authoritative agent install guide. Documents native, bun, and
  npm paths; **contains no Docker install path** and no containerised-workstation guidance.
- Live daemon: `signet status`, `signet dream status`, `curl /api/pipeline/status` — extraction
  reports disabled with reason `Dreaming owns semantic writes`.
- `gateway.json` and `modules/M-02877/darwin.nix` in this repo — gateway facts and the current
  LaunchAgent declarations.
- Three-persona `ce-doc-review` output for `docs/use-cases/token-efficiency.md` (31 findings).
- Caveman v2 release notes (proxy architecture, 54-run benchmark, pixel mode, licence split).

## Planning Contract

### Key Technical Decisions

- **KTD1 — Podman, not Apple `container` or Docker Desktop.** Apple `container` is running here and
  hosts three services, but Signet's first-party assets are Docker Compose files and Apple
  `container` has no compose support and no inter-container DNS. `podman-machine-default` already
  exists (applehv, 8 CPU, 16 GiB). Docker Desktop is not installed and adds a licence question.
  Podman runs the published compose file unchanged and gives `host.containers.internal` for reaching
  the loopback gateway shim.
- **KTD2 — The workspace is a bind mount, not a named volume, and SQLite integrity is the risk to
  manage.** The first-party compose file uses a named volume (`signet_data:/data/agents`), which is
  correct for a server but would fork the workspace away from `~/.agents`, where the harness
  connectors, transcript watcher, secret store, and this repo's own tooling expect it. Bind-mounting
  `~/.agents` keeps one source of truth. The cost is real: SQLite WAL over a virtiofs bind mount is
  a known corruption class, so U1's backup and U4's integrity check are not ceremony.
- **KTD3 — Auth stays single-user.** `deploy/docker/entrypoint.sh` writes `auth.mode: team` into
  `agent.yaml` on first run and the README mints bearer tokens. That is a server posture; this is a
  workstation. The migration pins single-user auth and asserts it after first boot, because a silent
  flip to team mode breaks every existing local caller at once.
- **KTD4 — The gateway auth shim stays a host service.** Dreaming cannot use an ACPX target on any
  native build (upstream #1731) and reaches the gateway through the loopback shim on 3851. The shim
  is nix-declared and reads its key from `secretspec` at start; moving it into the container network
  would drag the credential path in with it. The container reaches it via
  `host.containers.internal:3851`, and the target endpoint changes accordingly.
- **KTD5 — The setup guide becomes container-first for Signet.** Two documents drifted because both
  described the same configuration; the guide is the source of truth for install mechanics, so the
  container path lands there and the use-case page links to it.
- **KTD6 — The upstream report cites the build script, not just the symptom.**
  `scripts/build-signet-mcp.ts` lists `better-sqlite3` in `EXTERNAL` while `dist/signetai/package.json`
  declares no runtime dependencies, so the published bin cannot resolve it under node. Naming the
  mechanism is what makes the report actionable.

### Assumptions

Recorded because the scoping confirmation did not return before research continued:

- Podman is acceptable as a second container runtime alongside Apple `container` (KTD1).
- Bind-mounting the live workspace is preferred over an export/import into a container volume
  (KTD2).
- The loopback gateway shim stays on the host (KTD4).
- The docs recommend the Caveman v2 proxy rather than only describing it.

### High-Level Technical Design

```
                    host (macOS)
  ┌───────────────────────────────────────────────────────────┐
  │  harnesses: Claude Code hooks, omp extension, gemini,     │
  │  codex, hermes  ──────────────┐                           │
  │                               │ http 127.0.0.1:3850       │
  │  signet CLI entry point ──────┤ (DEC-1 decides its shape) │
  │                               ▼                           │
  │  ┌─────────────── podman machine (applehv) ────────────┐  │
  │  │  container: ghcr.io/signet-ai/signet                 │  │
  │  │    SIGNET_BIND 0.0.0.0, port 3850 → host loopback    │  │
  │  │    /data/agents  ← bind mount ~/.agents              │  │
  │  │    auth: single-user (KTD3)                          │  │
  │  └──────────────────────┬──────────────────────────────┘  │
  │                         │ host.containers.internal:3851   │
  │  gateway auth shim (nix-declared LaunchAgent) ────────────┼──► LEGO gateway
  └───────────────────────────────────────────────────────────┘
```

What the container does *not* inherit for free, and what each unit must therefore resolve: the host
`signet hook` binary the harness connectors call (U3), host paths for transcript capture and GraphIQ
indexing (U3), and the sqlite/vec environment that only mattered because macOS system SQLite refuses
`loadExtension()` — Linux in-container does not, so those two variables become unnecessary rather
than merely relocated (U4 asserts this rather than assuming it).

### Sequencing

U1 → U2 → U3 → U4 → U5 for the migration, gated on DEC-1. U6 is independent and lands first. U7 and
U8 both edit the same two files, so they are sequential, then U9 reviews and merges. U10 is
independent. U11 runs after the plan and beads exist and hands the rest to subagents.

## Implementation Units

| U-ID | Title | Files touched | Depends on |
|---|---|---|---|
| U1 | Restore-verified workspace backup | `~/.agents` (read), backup target outside it | DEC-1 |
| U2 | Containerised daemon on podman | new compose/quadlet under `modules/M-02877/`, `gateway.json` | U1 |
| U3 | Re-plumb host integrations | `~/.claude/settings.json` (via connector), `~/.claude.json`, `~/.omp/agent/extensions/` | U2 |
| U4 | Parity and durability verification | none (verification only) | U3 |
| U5 | Remove native path, deploy nix-darwin | `modules/M-02877/darwin.nix`, `~/.local/bin`, `/opt/homebrew` | U4 |
| U6 | Merge PR #85 | none (remote) | — |
| U7 | Setup-guide correction pass | `docs/guides/setup-token-saving-toolchain.md` (LEGO repo) | U6 |
| U8 | Caveman v2 pass | both LEGO docs pages | U7 |
| U9 | Review and merge second PR | same files | U8 |
| U10 | File `signet-mcp` upstream issue | none (remote) | — |
| U11 | Hand off executable work | handoff artifact | plan + beads |

### U1. Restore-verified workspace backup

**Goal:** A backup of `~/.agents` exists that has been proven restorable, so the migration's
stop condition can be evaluated rather than assumed.

**Requirements:** R3.

**Approach:** Stop the daemon so SQLite is quiescent. Capture the workspace with `signet export`
(the first-party portable bundle) *and* a filesystem-level archive, because the bundle is
schema-aware while the archive preserves `.secrets/`, `.native/`, and `.daemon/`. Verify by
restoring the archive to a scratch path and opening the restored database read-only with an
integrity check plus a row count — a backup that has not been read back is not a backup.

**Test scenarios:** archive restores to a scratch path; restored `memories.db` passes
`PRAGMA integrity_check`; restored row count matches the pre-backup count; `.secrets/` present in
the restored tree.

**Verification:** integrity check returns `ok`; counts match; scratch copy removed afterwards.

### U2. Containerised daemon on podman

**Goal:** The daemon serves `http://127.0.0.1:3850` from a container, restarts with its runtime, and
reads the existing workspace.

**Requirements:** R1.

**Files:** a compose or quadlet unit declared from `modules/M-02877/`, so the runtime declaration
lives with the host's other service declarations rather than in a hand-edited file.

**Approach:** Start `podman-machine-default`. Run the published image with the workspace bind-mounted
at `/data/agents`, the port published to loopback only, and single-user auth pinned per KTD3. Point
the dreaming target's endpoint at `host.containers.internal:3851`. Confirm the entrypoint did not
rewrite `agent.yaml`'s auth mode before any client depends on it.

**Test scenarios:** health endpoint returns ready; `agent.yaml` auth mode unchanged; container
survives `podman machine stop && start`; port is not reachable from a non-loopback interface.

**Verification:** `curl -sf --max-time 10 http://127.0.0.1:3850/health/ready`; auth-mode assertion;
restart survival.

### U3. Re-plumb host integrations

**Goal:** Every harness and host-side dependency reaches the containerised daemon, or its loss is
recorded explicitly.

**Requirements:** R5.

**Approach:** Reinstall each connector against the daemon URL that `DEC-1` selects. Re-point the
Signet MCP server entry. Establish that the container can see the transcript directories the watcher
needs, and that GraphIQ's index still resolves the paths it was built against — an index built on
host paths is useless to a container that mounts them elsewhere, so either the mount matches the host
path or the index is rebuilt.

**Test scenarios:** a Claude Code session-start hook returns success; the MCP server completes a
`tools/list` handshake; transcript capture reports healthy; `signet sources list` still shows 4 repos;
GraphIQ status reports an active project.

**Verification:** each of the five checks above, run against the container.

### U4. Parity and durability verification

**Goal:** The migration is proven, not presumed.

**Requirements:** R2.

**Approach:** Compare against the pre-migration baseline: recall mode, memory count, source count,
embedding coverage, dreaming worker state. Then restart the runtime and repeat. Assert that recall is
`hybrid` *without* the two macOS sqlite/vec variables, which is the mechanism KTD2 predicts and the
main structural win of the move.

**Test scenarios:** `signet recall` reports `hybrid`; memory count ≥ 81; 4-repo source present;
embedding coverage 1.0; dreaming worker running; all of it again after a runtime restart.

**Verification:** the commands in the Verification Contract, twice, with the second pass after
restart.

### U5. Remove native path and deploy nix-darwin

**Goal:** One supervision path remains.

**Requirements:** R4.

**Files:** `modules/M-02877/darwin.nix` (drop the `signet-daemon` agent, keep the shim),
`~/.local/bin/signet`, `/opt/homebrew/lib/node_modules/signetai`, `~/Library/LaunchAgents`.

**Approach:** Bootout and remove the hashed LaunchAgent, delete the native binary and npm package,
drop the nix-darwin block, then apply. Sequence matters: the container must already be serving before
the LaunchAgent is removed, or the harnesses lose their daemon mid-flight.

**Test scenarios:** no `ai.signet.daemon*` in `launchctl list`; both native artifacts absent;
`grep -c signet-daemon modules/M-02877/darwin.nix` returns 0; `just check` passes except the
pre-existing `oracleHost` failure; `just deploy-darwin` exits 0; the daemon still answers afterwards.

**Verification:** the four assertions plus `just check` and `just deploy-darwin`.

### U6. Merge PR #85

**Goal:** The reviewed accuracy pass on the use-case page is on `main`.

**Requirements:** R8.

**Approach:** Confirm mergeability and no failing required check, then merge. If a required review
blocks it, that is a stop condition, not something to work around.

**Verification:** `gh pr view 85 --json state,mergedAt` shows merged.

### U7. Setup-guide correction pass

**Goal:** The guide stops contradicting the tool and documents the container path.

**Requirements:** R6.

**Files:** `docs/guides/setup-token-saving-toolchain.md` in the LEGO repo.

**Approach:** Correct the retired per-session distillation framing, replace extraction-era
troubleshooting rows with dreaming-era ones, and replace the native Signet install instructions with
the container path this plan actually executed — the install section should describe what a colleague
can reproduce, which after U2 is the container. Every claim re-verified against the live system or the
tool's repository before it is written.

**Test scenarios:** no occurrence of the per-session framing remains; troubleshooting rows name
dreaming; the install path matches what U2 did; `npx prettier --check` passes with the repo config.

**Verification:** grep assertions plus prettier.

### U8. Caveman v2 pass

**Goal:** Both pages describe Caveman as it now ships.

**Requirements:** R7.

**Files:** `docs/guides/setup-token-saving-toolchain.md`, `docs/use-cases/token-efficiency.md`.

**Approach:** Verify each v2 claim against Caveman's own repository before writing: proxy wrapper
commands, the pinned 54-run benchmark figures, pixel mode's gate behaviour, the content-addressed
original store, and the BSL-1.1/MIT split. Replace the unsourced output-token figure with the
benchmark. Show Caveman on the wire as well as at the prompt in the request-path diagram.

**Test scenarios:** the unsourced figure is gone from both files; the benchmark is cited with its
method; the request-path diagram shows both positions; prettier passes.

**Verification:** grep assertions plus prettier; every figure traceable to a source named in the diff.

### U9. Review and merge second PR

**Goal:** The second docs change gets the same scrutiny as the first.

**Requirements:** R8.

**Approach:** Run the three-persona `ce-doc-review` against the diff, apply what the personas route
to apply, then open and merge.

**Test scenarios:** review returns findings for all three personas or names any that failed; P0/P1
findings are resolved or explicitly deferred in the PR body.

**Verification:** `gh pr view <second> --json state,mergedAt` shows merged.

### U10. File the `signet-mcp` upstream issue

**Goal:** The defect that breaks every harness spawning `signet-mcp` is reported.

**Requirements:** R9.

**Approach:** Report with the node reproduction, the `EXTERNAL` list in the build script, the empty
runtime-dependency set in the published wrapper, and the bun workaround. Search for duplicates first;
reference the two issues filed today as the same native-packaging family.

**Verification:** `gh issue view <new> --repo Signet-AI/signetai` resolves; URL returned.

### U11. Hand off executable work

**Goal:** The remaining execution runs on Sonnet 5 subagents with the plan and beads as their
contract.

**Requirements:** R10.

**Approach:** Use the `handoff` skill to produce the artifact, scoped per track, with bead IDs, the
verification commands, and the stop conditions carried verbatim.

**Verification:** handoff artifact readable; each track's bead IDs present in it.

## Verification Contract

```bash
# Signet parity (run before migration for a baseline, after U4, and again after a runtime restart)
signet status
signet doctor
signet recall "nix darwin deploy"        # must report (hybrid)
signet sources list                       # must list 4 repos
signet embed audit                        # coverage 1.0
signet dream status
curl -sf --max-time 10 http://127.0.0.1:3850/health/ready

# Native path removal
test ! -e ~/.local/bin/signet
test ! -e /opt/homebrew/lib/node_modules/signetai
launchctl list | grep -c ai.signet.daemon        # 0
grep -c signet-daemon modules/M-02877/darwin.nix  # 0

# Host config
just check          # four host evals; pre-existing oracleHost failure allowed
just deploy-darwin  # exit 0

# Docs
npx prettier --check <changed markdown>   # repo .prettierrc
gh pr view 85 --json state,mergedAt
gh pr view <second> --json state,mergedAt

# Upstream
gh issue view <new> --repo Signet-AI/signetai

# Beads
bd ready
```

## Definition of Done

Global: every requirement R1-R10 has direct evidence from the commands above, captured after the last
change rather than from an earlier run. No scaffolding remains — no scratch restore directory, no
second daemon, no leftover compose file outside the declared location, and no abandoned migration
attempt left in the repo.

Per unit: the unit's own verification block passes. U1 is done only when the backup has been read
back. U4 is done only when the checks pass twice with a runtime restart between them. U5 is done only
when the daemon still answers after the LaunchAgent is gone.

## Open Questions

- **DEC-1 (blocking, owns U1-U5): what is the CLI entry point after the native binary is deleted?**
  Success criterion 4 of the objective asks for `~/.local/bin/signet` absent *and* for
  `signet doctor` / `signet status` / `signet recall` as the verification commands. Those cannot both
  hold on the host: with no host binary there is no host `signet`. Three resolutions, each with a
  different cost:
  1. **A thin host wrapper** at `~/.local/bin/signet` that execs into the container. Verification
     commands keep working verbatim and harness hooks keep working. The native *binary* is gone but
     the path is occupied, so "native path gone" holds in substance, not literally.
  2. **Container-only CLI** (`podman exec signet signet …`). Literal criterion satisfied. Harness
     hooks that shell out to `signet hook` break unless every connector is reinstalled as a remote
     connector with an API key, which is supported but changes five integrations at once.
  3. **Remote-connector posture**: mint an API key, reinstall connectors against the daemon URL, and
     accept that ad-hoc CLI use goes through the container. Closest to the first-party server design,
     furthest from how this machine currently works.

  Recommendation: option 1 — it satisfies R4's substance while keeping R5 intact, and it is the only
  one where a failed migration is a one-line revert. This needs a human answer because it trades the
  literal wording of a success criterion against five working integrations.

## Appendix

**Why the first-party container assets do not drop in unchanged.** `deploy/docker/compose.yml` sets
`SIGNET_BIND: 0.0.0.0`, mounts a named volume, and pairs the daemon with Caddy on 80/443;
`deploy/docker/entrypoint.sh` writes `auth.mode: team` on first run, and the README's bootstrap step
mints an admin bearer token. That is a deliberate self-hosted-server shape. The authoritative agent
install guide at `https://signetai.sh/skill.md` documents only the native, bun, and npm paths and
states that Signet "never installs system services (launchd/systemd) automatically" — which is also
why the LaunchAgent this plan removes was never part of the documented contract. A workstation
migration therefore borrows the image and discards the server posture: loopback publish instead of
`0.0.0.0` exposure through Caddy, bind mount instead of named volume, single-user auth instead of
team.
