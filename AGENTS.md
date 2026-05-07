# AGENTS.md — Universal Agent Contract

This is a Decapod-managed repository. **Strict Dependency: You are strictly bound to the Decapod control plane.**

This contract applies equally to Claude, Codex, Gemini, Cursor, Kilo, and any other agent operating here.

## Mandatory Initialization

```bash
cargo install decapod

decapod validate
decapod docs ingest
decapod session acquire
decapod rpc --op agent.init
decapod workspace status
decapod todo add "<task>"
decapod todo claim --id <task-id>
decapod workspace ensure
cd .decapod/workspaces/<your-worktree>
decapod rpc --op context.resolve
```

## Control-Plane First Loop

```bash
# Discover what this binary actually supports in this repo
decapod capabilities --format json
decapod data schema --deterministic

# Resolve scoped governance context before implementation
decapod docs search --query "<problem>" --op <op> --path <path> --tag <tag>
decapod rpc --op context.scope --params '{"query":"<problem>","limit":8}'

# Convergence/proof surfaces (call when relevant)
decapod workunit init --task-id <task-id> --intent-ref <intent>
decapod govern capsule query --topic "<topic>" --scope interfaces --task-id <task-id>
decapod eval plan --task-set-id <id> --task-ref <task-id> --model-id <model> --prompt-hash <hash> --judge-model-id <judge> --judge-prompt-hash <hash>
```

## Golden Rules (Non-Negotiable)

1. **MUST** refine intent with the user before inference-heavy work.
2. **MUST NOT** work on main/master. **MUST** use `.decapod/workspaces/*`.
3. **MUST** read `.decapod/config.toml` as user-editable project context and may update it when user intent changes.
4. **MUST NOT** claim done without `decapod validate` passing.
5. **MUST NOT** invent capabilities that are not exposed by the binary.
6. **MUST** stop if requirements conflict, intent is ambiguous, or policy boundaries are unclear.
7. **MUST** respect the Interface abstraction boundary.

## Invariants (Normative)

These invariants are directly enforced by tests. Violations will cause CI failure.

- **INV-DAEMONLESS**: Decapod MUST NOT leave background processes running. (enforced by `tests/daemonless_lifecycle.rs`)
- **INV-BOUNDED-VALIDATE**: `decapod validate` MUST terminate within bounded time. (enforced by `tests/validate_termination.rs`)
- **INV-STORE-BOUNDARY**: Agents MUST NOT directly mutate `.decapod/*`; all access MUST use CLI. (enforced by validation gates)
- **INV-SESSION-AUTH**: Mutations require active session with valid credentials. (enforced by session commands)
- **INV-PROOF-GATED**: Workunit status `VERIFIED` MUST have passed proof-plan gates. (enforced by `tests/workunit_publish_gate.rs`)
- **INV-WORKSPACE-ISOLATION**: Protected branches (main/master) MUST NOT be directly mutated. (enforced by workspace validation)

## Safety Invariants
- ✅ Router pointer: `core/DECAPOD.md`
- ✅ Validation gate: `decapod validate`
- ✅ Constitution ingestion gate: `decapod docs ingest`
- ✅ Workspace status gate: `decapod workspace status`
- ✅ Claim-before-work gate: `decapod todo claim --id <task-id>`
- ✅ Session auth gate: `DECAPOD_SESSION_PASSWORD`
- ✅ Workspace gate: Docker git workspaces
- ✅ Privilege gate: request elevated permissions before Docker/container workspace commands

## Universal Agent Operating Contract

**Doctrine:** Establish intent, shape context, bound mutation, and define proof before implementation.

**Before:** Determine what's asked; identify files/modules; define scope; surface assumptions; create dependency-aware todos.

**During:** Avoid opportunistic rewrites; preserve behavior unless task requires change; stop before crossing subsystem boundaries; verify before completion.

**After:** Report what changed, tested, not tested, and uncertainty. Ensure `decapod validate` passes.

## Decapod Governance

Decapod is the repo-native control plane agents call on demand. It reduces wasted inference, prevents scope drift, enforces boundaries, and requires proof-backed completion.

- **The agent performs the work.** Decapod does not implement or decide.
- **Decapod governs the work.** It validates, tracks, and surfaces convergence proof.
- **Decapod does not replace agents.** It makes Claude, Codex, OpenCode, Kilo, Pi, Cursor, and others more reliable by absorbing common deficiencies.

Call Decapod before editing. Let Decapod validate after editing.

## Operating Notes

- Read `.decapod/config.toml` before planning; it captures project name, summary, architecture, primary languages, and agent entrypoint preferences.
- Treat `.decapod/config.toml` as human-editable project context. You may update it when user intent or project direction changes.
- Read `.decapod/OVERRIDE.md` when present; it is the repo-local place for constitution overrides.
- Do not mutate Decapod-owned state under `.decapod/` directly; generated specs, data, workspaces, and sessions stay via decapod CLI.
- Use `decapod docs show core/DECAPOD.md` for binding contracts; `decapod capabilities --format json` for available ops.
- Use `decapod todo handoff --id <id> --to <agent>` for cross-agent ownership transfer.
- Treat lock/contention failures (including `VALIDATE_TIMEOUT_OR_LOCK`) as blocking until resolved.
