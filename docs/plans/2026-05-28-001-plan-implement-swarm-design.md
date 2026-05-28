---
title: "design: Replace plan-implement chain with Decapod/Beads/Agent Mail swarm"
status: draft
created: 2026-05-28
origin: grill-me design session with Decapod PR #587, Beads best practices, Agent Mail, and pi-subagents research
depth: standard
bead: home-manager-7hg
---

# design: Replace plan-implement chain with Decapod/Beads/Agent Mail swarm

## Summary

Replace the existing static `plan-implement.chain.md` workflow with a Home Manager-managed `plan-implement` skill that orchestrates a parallel, Beads-driven, Decapod-isolated, Agent Mail-coordinated worker swarm.

The old chain is static and cannot safely perform dynamic fan-out/fan-in. The new skill becomes the authoritative entrypoint. It plans outside Beads, imports/refines a Beads epic and child issue DAG, runs one fresh subagent per ready Bead in isolated worktrees, validates with Decapod, coordinates through Agent Mail, and serializes integration with `bd merge-slot`.

## Problem Frame

The current topology has four saved chains:

- `scout-plan`: scout → planner
- `plan-implement`: planner → worker → reviewer → workstream-compounder
- `review-fix`: reviewer → worker → reviewer → workstream-compounder
- `ce-review`: parallel CE reviewers → adversarial reviewer

This works for sequential single-worker loops, but not for multi-lane execution. The Reddit topology distinguishes two modes:

1. Single-worker reliable loop: saved chains write/read `plan.md` and `review.md` until clean.
2. Parallel worker fanout: direct `pi-subagents` tool syntax from a `SKILL.md`, not `.chain.md`, because lane count and fan-in are dynamic.

Decapod and Beads now make the parallel mode feasible if their boundaries are explicit:

- Beads provides passive execution tracking, issue DAGs, worktree-aware shared DB, swarms, merge slots, and durable issue memory.
- Decapod provides Shadow Custody, workspace/container validation, blockers, workunits, proof surfaces, and publish artifacts.
- Agent Mail provides agent identity, Bead-threaded messaging, inbox/outbox history, and warning-mode file reservations across worktrees.
- Pi-subagents provides the worker/reviewer execution substrate.

## Key Decisions

1. **Replace chain with skill** — `plan-implement.chain.md` is removed from Home Manager chain registration. A new `plan-implement` skill owns dynamic orchestration.
2. **Beads is canonical task board** — Beads epic + child issue DAG is source of truth for work partitioning, dependencies, and lane ownership.
3. **Decapod Shadow Custody wraps Beads work** — Each lane exports `BEADS_TASK_ID`/`BD_TASK_ID` and runs Decapod workspace/container/proof flows. Decapod yields branch naming to Beads while maintaining safety.
4. **Agent Mail required** — All workers, reviewers, and orchestrator use Agent Mail. Thread ID = Bead ID. File reservations start in warn mode.
5. **Beads creates worktrees** — `bd worktree create <bead-id>-<slug>` creates worktree and branch. Decapod validates/containers the existing worktree.
6. **One Bead per worker run** — Workers are fresh subagent sessions. Beads/Decapod/Agent Mail carry state between sessions.
7. **Path scope required** — Every child Bead must declare file/path globs before fanout. Overlapping write scopes block parallelism and become dependencies or same-Bead work.
8. **Pre-worker refinement cap** — Up to 5 plan refinement rounds and up to 5 Beads-DAG polish rounds. Stop early when no material improvement remains.
9. **Oracle before DAG finalization** — Run oracle after draft DAG/refinement and before spawning workers; run final oracle only if architecture/scope changed materially.
10. **Concurrency heuristic** — Use GPU count if NVIDIA/ROCm GPUs are detected; otherwise `max(1, floor(logical_cpu_count / 4))`. Cap by ready non-overlapping Beads.
11. **Two-tier review** — Per-lane review before publish, then integrated review after serial fan-in.
12. **Merge slot required** — Only orchestrator/integration worker may hold `bd merge-slot`. Fan-in merges one lane at a time.
13. **Bead closure after integrated validation** — Worker marks lane integration-ready with proof; orchestrator closes Bead only after merge and integrated validation.
14. **Coverage requirement** — Literal whole-repo 100% unit coverage. If coverage tooling is missing, create and complete a prerequisite coverage-infra Bead before feature lanes.
15. **Final integrated push only** — Lane branches stay local unless fan-in is blocked or audit mode later requires remote branches. Final integrated branch is pushed.
16. **Agent Mail install via HM activation** — Use upstream installer every deploy with `--no-start --skip-beads --skip-bv`; Home Manager manages `br`/`bv` separately and owns Pi MCP config.

## Runtime Workflow

### 1. Preflight

The `plan-implement` skill checks:

- `bd` available and repository initialized.
- Decapod initialized and `.decapod/OVERRIDE.md` read when present.
- Decapod external tracker support enabled via repo opt-in and per-lane env var plan.
- Agent Mail installed by upstream installer.
- Agent Mail worktree mode enabled: `WORKTREES_ENABLED=1`.
- Agent Mail guard mode set to warn: `AGENT_MAIL_GUARD_MODE=warn`.
- `pi-mcp-adapter` available and Pi MCP config points to Agent Mail.
- `br`/`bv` managed by Home Manager if enabled.
- Coverage command/threshold exists, or coverage-infra Bead is created first.
- `decapod validate` and repo-specific gates are discoverable.

If any hard prerequisite is missing, fail closed with exact setup action.

### 2. Plan outside Beads

Planner/scout gathers:

- User goal and non-goals.
- Existing code patterns and integration points.
- AGENTS/CLAUDE/Decapod override obligations.
- Repo test, lint, build, coverage, and deployment gates.
- Expected file/path scopes.
- Risks, blockers, and approval gates.

Planner may refine up to 5 rounds.

### 3. Import and polish Beads DAG

Create Beads epic for whole request. Create child Beads for atomic work units.

Each child Bead must include:

- Goal and acceptance criteria.
- File/path scope globs.
- Dependencies.
- Validation gates.
- Coverage expectations.
- Agent Mail thread convention.
- Decapod proof expectations.
- Integration notes.

Polish Beads DAG up to 5 rounds. Review for:

- Missing dependencies.
- Overlapping write scopes.
- Too-large tasks.
- Missing test/coverage gates.
- Missing risks/dangers.
- Parallelization safety.

Run oracle before finalizing DAG.

### 4. Select ready lanes

Compute ready lanes:

- Child Beads unblocked by dependencies.
- Non-overlapping write scopes.
- Within concurrency cap.
- Coverage-infra Bead completed first if needed.
- No Bead already claimed by another actor.

For this host today, shell heuristic reports 8 logical CPUs and no NVIDIA/ROCm GPU, so default cap is 2 lanes.

### 5. Start lane worker

For each lane:

1. Claim Bead.
2. Create worktree/branch:
   ```bash
   bd worktree create <bead-id>-<slug>
   ```
3. Enter worktree.
4. Export:
   ```bash
   export BEADS_TASK_ID=<bead-id>
   export BD_TASK_ID=<bead-id>
   export WORKTREES_ENABLED=1
   export AGENT_MAIL_GUARD_MODE=warn
   ```
5. Run Decapod validation/container setup:
   ```bash
   decapod workspace ensure --container
   ```
6. Register Agent Mail identity.
7. Open/send Bead thread with `thread_id=<bead-id>`.
8. Reserve planned file/path globs in warn mode.
9. Launch fresh `worker` subagent in that worktree.

Worker contract:

- Work only on assigned Bead.
- Use Bead and Agent Mail thread as task context.
- Do not close Bead.
- Run lane gates and coverage-relevant tests.
- Run `decapod validate`.
- Commit lane changes locally.
- Run Decapod publish/proof.
- Post Agent Mail completion with changed files, validation evidence, proof artifact, blockers, and integration notes.
- Mark Bead integration-ready or blocked.

### 6. Per-lane review

After worker completes, run fresh reviewer(s) in lane worktree:

- Correctness/regression.
- Tests/coverage/gates.
- Scope/path compliance.
- Decapod/Agent Mail/Beads protocol compliance.

Reviewer reports findings to Bead thread and Bead notes. If fixes are needed, spawn one fresh retry worker for that Bead. If retry fails, mark blocked with evidence.

### 7. Fan-in under merge slot

Orchestrator acquires merge slot:

```bash
bd merge-slot acquire
```

For each integration-ready lane, in dependency order:

1. Apply/merge lane branch into integration branch.
2. Resolve conflicts only through one integration-fix worker if needed.
3. Run focused validation.
4. Run `decapod validate`.
5. Run coverage check toward 100% whole-repo coverage.
6. Run integrated review when warranted.
7. Close Bead only after integrated validation passes.
8. Release merge slot when safe.

If integration-fix worker fails once, reopen/block involved Beads and post Agent Mail blocker.

### 8. Final validation

Epic can close only when:

- All child Beads closed.
- `bd merge-slot` released.
- `decapod validate` passes.
- Whole-repo unit coverage is 100%.
- Tests/lints/builds/gates pass.
- Final integrated CE review has no blockers, functional gaps, risks, or dangers.
- Agent Mail threads have completion summaries.
- Final integrated branch pushed.

## Home Manager Implementation Plan

### U1. Add Pi MCP support

Files:

- `modules/shared-devtools.nix`

Changes:

- Add `npm:pi-mcp-adapter` to Pi packages.
- Add HM-owned MCP config for Agent Mail endpoint/tooling.
- Ensure config does not embed secrets in Nix store unless endpoint is local unauthenticated or token is runtime-resolved.

Open detail:

- Confirm exact Pi MCP config file shape expected by `pi-mcp-adapter`.

### U2. Add Agent Mail installer activation

Files:

- `modules/shared-devtools.nix`

Changes:

- Add activation step that runs upstream installer every deploy.
- Use flags:
  ```bash
  --yes --no-start --skip-beads --skip-bv
  ```
- Do not let installer manage Pi config.
- Do not start server during activation.

Open detail:

- Confirm installer supports a project/config path that avoids writing HM-managed Pi settings when `--no-start` is used.

### U3. Add managed br/bv packages or wrappers

Files:

- `modules/shared-devtools.nix`
- Possibly `pkgs/` overlays if packages are not available.

Changes:

- Add managed `br` and `bv` if available or package them separately.
- Preserve existing `bd` workflow until migration is explicit.

Open detail:

- Confirm whether current `bd` is Go or Rust and whether `merge-slot`/`swarm` semantics match desired version.

### U4. Add `plan-implement` skill

Files:

- `pi-extensions/skills/plan-implement/SKILL.md`
- `modules/shared-devtools.nix`

Changes:

- Add skill with this design as executable protocol.
- Skill must use direct `subagent(...)` JSON, not saved chain mode, for dynamic fanout.
- Skill must require Beads/Decapod/Agent Mail preflight.
- Skill must stop at hard prerequisite failures.

### U5. Remove old chain registration

Files:

- `modules/shared-devtools.nix`
- `pi-extensions/chains/plan-implement.chain.md` may remain in repo as archive or be deleted.

Changes:

- Remove `home.file.".pi/agent/chains/plan-implement.chain.md"` source registration.
- Optionally move old chain to archive path if useful.

### U6. Validate and deploy

Commands:

```bash
just check
just deploy-mahakala-hm
pi subagent list
```

Additional checks:

- Confirm `plan-implement` skill appears in Pi skill discovery.
- Confirm `plan-implement` chain no longer appears in subagent chain list.
- Confirm `pi-mcp-adapter` package installed.
- Confirm Agent Mail installer did not replace `bd`.
- Confirm `am` start script exists.

## Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| Upstream Agent Mail installer mutates HM-owned Pi config | Use `--no-start`; HM owns MCP config; verify diff after activation |
| Networked installer every deploy causes flakiness | Accept per user decision; fail deploy visibly |
| Literal 100% coverage is infeasible in some repos | Create coverage-infra Bead; fail closed if impossible |
| Parallel lanes edit same files | Require path scopes; overlap blocks parallelism |
| Beads/Decapod task state drifts | Beads canonical; Decapod Shadow Custody internal coordination only |
| Agent Mail reservations false-positive | Warn mode in v1 |
| Fan-in corrupts integration branch | Mandatory `bd merge-slot`; one lane at a time; validation after each merge |
| Context drift in long-lived workers | One Bead per fresh worker run |
| pi-subagents intercom limitations | Agent Mail required; pi-intercom not used for heavy lane coordination |

## Oracle Review Resolutions

Oracle review found three blockers. Current resolution:

1. **Skill hosting** — Pi docs confirm global skills are discovered from `~/.pi/agent/skills/` and directories containing `SKILL.md` are discovered recursively. Home Manager can source `pi-extensions/skills/plan-implement/SKILL.md` into that location.
2. **Agent Mail distribution** — Upstream is `Dicklesworthstone/mcp_agent_mail`. It is installed by the upstream installer. PyPI package names are not trusted because upstream release notes say similarly named packages may be different projects. Activation uses upstream installer flags `--yes --no-start --skip-beads --skip-bv`.
3. **Decapod/Beads workspace split** — PR #587 adds Shadow Custody for external trackers. Lane prompts export `BEADS_TASK_ID`/`BD_TASK_ID`, and repos opt into external tracker mode. Decapod runs as validator/container/proof layer over Beads-created worktrees. Skill uses bounded timeout and follows Decapod `blockers`/`resolve_hint` output instead of bypassing container requirements.

Oracle concerns intentionally retained:

- Literal 100% coverage remains user-approved despite feasibility risk.
- Agent Mail remains hard prerequisite, not v1 fallback.
- Concurrency remains GPU-count else CPU/4 per user decision.

## Open Questions Before Implementation

1. Whether `br`/`bv` are available through existing Nix inputs or need custom packages.
2. Whether old `pi-extensions/chains/plan-implement.chain.md` should be deleted or retained unregistered for history.
3. How to test the skill without launching a full swarm against the Home Manager repo.

## Acceptance Criteria

- `plan-implement` chain is no longer registered by Home Manager.
- `plan-implement` skill exists and documents the swarm protocol.
- Pi packages include `npm:pi-mcp-adapter`.
- Agent Mail installer activation exists with agreed flags.
- Beads remains managed separately; installer does not replace `bd`.
- Design decisions above are reflected in skill text.
- Validation/deploy commands pass or blockers are documented in Bead `home-manager-7hg`.
