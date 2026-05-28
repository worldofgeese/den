---
name: plan-implement
description: Plan and implement software work through a Decapod/Beads/Agent Mail swarm. Replaces the old static plan-implement chain. Use when the user asks to plan+implement, run plan-implement, fan out workers, or execute a substantial software change end-to-end.
argument-hint: "[software goal]"
---

# Plan Implement Swarm

You are the parent orchestrator. Do not use `/run-chain plan-implement`; that static chain is deprecated. Use direct `subagent(...)` calls plus Beads, Decapod, and Agent Mail.

## Hard prerequisites

Fail closed with exact missing setup when any required surface is absent:

- Beads CLI available and repo initialized.
- Decapod initialized.
- `pi-mcp-adapter` available to Pi.
- MCP Agent Mail installed and startable via upstream `am`/`run_server_with_token.sh` flow.
- If `am` is absent but `~/.config/mcp-agent-mail` exists, use that repo's `scripts/run_server_with_token.sh` directly.
- Agent Mail worktree mode enabled: `WORKTREES_ENABLED=1`.
- Agent Mail reservations warn mode: `AGENT_MAIL_GUARD_MODE=warn`.
- Decapod external tracker mode enabled durably for repo plus per-lane env vars.
- Coverage tooling exists or a prerequisite coverage-infra Bead can be created.

Never let Agent Mail installer replace Beads. Home Manager owns `br`/`bv` and Pi MCP config.

## Authority model

- Beads is canonical task board and task DAG.
- Decapod owns workspace/container/proof safety.
- Agent Mail owns lane communication and warning-mode file reservations.
- Pi-subagents owns execution only.
- Parent orchestrator owns loop completion. Reviewers can recommend; they do not decide done.

## Workflow

### 1. Preflight and context

1. Read repo instructions: `AGENTS.md`, `CLAUDE.md`, `.decapod/OVERRIDE.md` when present.
2. Check `bd`, `decapod`, Agent Mail, MCP config, and coverage command.
3. Start Agent Mail on demand using upstream start flow if not running.
4. Discover validation gates from repo scripts, CI config, Decapod preflight/impact, and project instructions.
5. Detect concurrency:
   - NVIDIA/ROCm GPU count when available.
   - Else `max(1, floor(logical_cpu_count / 4))`.
   - Cap by ready non-overlapping Beads.

### 2. Plan outside Beads

Use scout/planner/oracle as needed. Refine plan up to 5 rounds, stopping early when no material improvement remains.

Plan must include:

- Goal, non-goals, scope boundaries.
- Integration points and existing patterns.
- Required files/path globs.
- Validation gates.
- Coverage path to whole-repo 100% unit coverage.
- Risks, dangers, and decision gates.

### 3. Create and polish Beads DAG

Create one Beads epic for the request. Create child Beads for atomic work units.

Each child Bead must include:

- Acceptance criteria.
- Write/read path scopes as globs.
- Dependencies.
- Validation and coverage gates.
- Decapod proof expectations.
- Agent Mail thread ID: Bead ID.

Polish Beads DAG up to 5 rounds. Overlapping write scopes must become dependencies or same-Bead work. Do not fan out overlapping write scopes.

Run `oracle` before finalizing DAG for non-trivial work. If oracle unavailable, record blocker and either ask user or proceed only if user explicitly accepts degraded review.

### 4. Spawn lanes

For each ready, non-overlapping child Bead up to concurrency cap:

1. Claim Bead.
2. Create Beads worktree/branch:
   ```bash
   bd worktree create <bead-id>-<slug>
   ```
3. In worktree, export:
   ```bash
   export BEADS_TASK_ID=<bead-id>
   export BD_TASK_ID=<bead-id>
   export WORKTREES_ENABLED=1
   export AGENT_MAIL_GUARD_MODE=warn
   ```
4. Run with bounded timeout and inspect JSON/text blockers:
   ```bash
   timeout 120 decapod workspace ensure --container
   ```
   If Decapod reports a required `--branch`, pass the Beads-created branch name. If Decapod reports container blockers, follow its `resolve_hint` instead of bypassing container mode.
5. Register Agent Mail identity.
6. Use Agent Mail `thread_id=<bead-id>` and subject prefix `[<bead-id>]`.
7. Reserve planned path globs in warn mode.
8. Launch one fresh `worker` subagent in that worktree.

Worker contract:

- Work only assigned Bead.
- Do not close Bead.
- Run focused gates and coverage-relevant tests.
- Run `decapod validate`.
- Commit lane changes locally.
- Run Decapod publish/proof where available.
- Post Agent Mail completion and Bead note with changed files, validation evidence, proof artifacts, blockers, and integration notes.
- Mark Bead integration-ready or blocked.

### 5. Per-lane review

After each worker completes, run fresh reviewer(s) in lane worktree for:

- Correctness/regression.
- Test/coverage quality.
- Scope/path compliance.
- Beads/Decapod/Agent Mail protocol compliance.

If fix needed, spawn one fresh retry worker for that Bead. If retry fails, mark Bead blocked, release reservations, and post Agent Mail blocker.

### 6. Fan-in

Acquire merge slot before integration:

```bash
bd merge-slot acquire
```

Merge one lane at a time in dependency order.

For each lane:

1. Apply/merge lane branch into integration branch.
2. If merge conflict or integrated test failure occurs, spawn one integration-fix worker under merge slot.
3. Run focused validation.
4. Run `decapod validate`.
5. Run coverage check toward literal whole-repo 100% unit coverage.
6. Close Bead only after integrated validation passes.

Release merge slot when safe.

### 7. Final done gate

Epic is done only when:

- All child Beads closed.
- Merge slot released.
- `decapod validate` passes.
- Tests/lints/builds/project gates pass.
- Whole-repo unit coverage is 100%.
- Integrated CE review has no blockers, functional gaps, risks, or dangers.
- Agent Mail threads contain completion summaries.
- Final integrated branch is pushed.

Push final integrated branch only. Do not push lane branches unless fan-in is blocked or audit mode is explicitly enabled.

## Implementation note

Use direct `subagent(...)` JSON with `cwd` per lane worktree. Do not use static `.chain.md` files for dynamic worker fanout.
