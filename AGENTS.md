# AGENTS.md

This file provides guidance to AI coding agents when working with this repository.

## Project Overview

This project follows Spec-Driven Development (SDD). Behavioral specs live in `.rpi/specs/` and serve as the source of truth for expected behavior. Always consult relevant specs before implementing or modifying features.

<!-- TODO: Add brief project description -->

## Git Workflow

When committing changes, always ask the user which files/directories to include before proposing commits. Never assume all unstaged/staged changes should be committed.

## Update and Deploy Commands

Use the repository `Justfile` for updates and deployments instead of running the underlying Nix/Guix commands directly.

- `just update` updates all flake inputs and then runs `just update-rust-tools` so pinned Rust tools stay current.
- `just update-rust-tools` refreshes Rust tool pins in `modules/overlays.nix` to the latest upstream releases and recomputes source and Cargo hashes.
- `just update-input <input>` updates one flake input only; run `just update-rust-tools` separately if Rust tool pins should also be refreshed.
- `just check` runs `nix flake check --all-systems`.
- `just deploy-mahakala` updates and deploys Guix System, Guix Home, and Home Manager for mahakala.
- `just deploy-mahakala-hm` updates and applies only the mahakala Home Manager profile.
- `just deploy-mahakala-guix` applies only Guix Home for mahakala.
- `just deploy-mahakala-system` applies only Guix System for mahakala.
- `just deploy-paphos [host]` updates and deploys the paphos NixOS configuration to the target host.
- `just deploy-darwin` updates and applies the nix-darwin configuration for M-02877.
- `just deploy-pixel-fold` updates and applies the nix-on-droid configuration for pixel-fold.
- `just upgrade-kernel` refreshes the CachyOS kernel package metadata.

## RPI Artifacts Directory

This project uses a `.rpi/` directory for persistent context:

```
.rpi/
├── research/      # Codebase research notes (optional, from /rpi-research)
├── designs/       # Solution designs (created by /rpi-propose)
├── plans/         # Implementation plans (created by /rpi-plan)
├── specs/         # Living behavioral specs
├── reviews/       # Verification reports
├── diagnoses/     # Bug diagnosis post-mortems (created by /rpi-diagnose)
├── archive/       # Archived completed artifacts
```

### Development Pipeline

Workflow: Research → Propose → Plan → Implement → Verify

- **Research** (`/rpi-research`): Investigate the codebase. Optional.
- **Propose** (`/rpi-propose`): Analyze trade-offs, write design + spec (behavioral contract). Approval gate.
- **Plan** (`/rpi-plan`): Create phased implementation plan from approved spec.
- **Implement** (`/rpi-implement`): Execute plan phase-by-phase with verification.
- **Verify** (`/rpi-verify`): Validate spec conformance.

Each command suggests the next step. Start with `/rpi-propose` for features, `/rpi-plan` for bug fixes, `/rpi-research` when exploring.

## Development Conventions

Before implementing any changes, always: 1) Read the current version of each file you plan to modify, 2) Run the existing test suite to establish a baseline, 3) Implement changes incrementally — one logical unit at a time, 4) Run tests after each unit. If tests fail, fix before proceeding. Do not batch all changes and test at the end.
<!-- TODO: Add project-specific conventions -->

When implementing a plan from `.rpi/plans/`, present intended changes for each phase before writing code. If a phase's success criteria are fully covered by automated checks (tests, linting, etc.), run them and proceed automatically when they pass. Only pause for manual verification when the plan includes manual verification items not covered by automated tests. Update checkboxes in the plan file as items complete, and resume from the first unchecked item if checkboxes already exist.

---

# context-mode — MANDATORY routing rules

context-mode MCP tools available. Rules protect context window from flooding. One unrouted command dumps 56 KB into context.

## Think in Code — MANDATORY

Analyze/count/filter/compare/search/parse/transform data: **write code** via `context-mode_ctx_execute(language, code)`, `console.log()` only the answer. Do NOT read raw data into context. PROGRAM the analysis, not COMPUTE it. Pure JavaScript — Node.js built-ins only (`fs`, `path`, `child_process`). `try/catch`, handle `null`/`undefined`. One script replaces ten tool calls.

## BLOCKED — do NOT attempt

### curl / wget — BLOCKED
Shell `curl`/`wget` intercepted and blocked. Do NOT retry.
Use: `context-mode_ctx_fetch_and_index(url, source)` or `context-mode_ctx_execute(language: "javascript", code: "const r = await fetch(...)")`

### Inline HTTP — BLOCKED
`fetch('http`, `requests.get(`, `requests.post(`, `http.get(`, `http.request(` — intercepted. Do NOT retry.
Use: `context-mode_ctx_execute(language, code)` — only stdout enters context

### Direct web fetching — BLOCKED
Use: `context-mode_ctx_fetch_and_index(url, source)` then `context-mode_ctx_search(queries)`

## REDIRECTED — use sandbox

### Shell (>20 lines output)
Shell ONLY for: `git`, `mkdir`, `rm`, `mv`, `cd`, `ls`, `npm install`, `pip install`.
Otherwise: `context-mode_ctx_batch_execute(commands, queries)` or `context-mode_ctx_execute(language: "shell", code: "...")`

### File reading (for analysis)
Reading to **edit** → reading correct. Reading to **analyze/explore/summarize** → `context-mode_ctx_execute_file(path, language, code)`.

### grep / search (large results)
Use `context-mode_ctx_execute(language: "shell", code: "grep ...")` in sandbox.

## Tool selection

0. **MEMORY**: `context-mode_ctx_search(sort: "timeline")` — after resume, check prior context before asking user.
1. **GATHER**: `context-mode_ctx_batch_execute(commands, queries)` — runs all commands, auto-indexes, returns search. ONE call replaces 30+. Each command: `{label: "header", command: "..."}`.
2. **FOLLOW-UP**: `context-mode_ctx_search(queries: ["q1", "q2", ...])` — all questions as array, ONE call (default relevance mode).
3. **PROCESSING**: `context-mode_ctx_execute(language, code)` | `context-mode_ctx_execute_file(path, language, code)` — sandbox, only stdout enters context.
4. **WEB**: `context-mode_ctx_fetch_and_index(url, source)` then `context-mode_ctx_search(queries)` — raw HTML never enters context.
5. **INDEX**: `context-mode_ctx_index(content, source)` — store in FTS5 for later search.

## Parallel I/O batches

For multi-URL fetches or multi-API calls, **always** include `concurrency: N` (1-8):

- `context-mode_ctx_batch_execute(commands: [3+ network commands], concurrency: 5)` — gh, curl, dig, docker inspect, multi-region cloud queries
- `context-mode_ctx_fetch_and_index(requests: [{url, source}, ...], concurrency: 5)` — multi-URL batch fetch

**Use concurrency 4-8** for I/O-bound work (network calls, API queries). **Keep concurrency 1** for CPU-bound (npm test, build, lint) or commands sharing state (ports, lock files, same-repo writes).

GitHub API rate-limit: cap at 4 for `gh` calls.

## Output

Write artifacts to FILES — never inline. Return: file path + 1-line description.
Descriptive source labels for `search(source: "label")`.

## Session Continuity

Skills, roles, and decisions persist for the entire session. Do not abandon them as the conversation grows.

## Memory

Session history is persistent and searchable. On resume, search BEFORE asking the user:

| Need | Command |
|------|---------|
| What did we decide? | `context-mode_ctx_search(queries: ["decision"], source: "decision", sort: "timeline")` |
| What constraints exist? | `context-mode_ctx_search(queries: ["constraint"], source: "constraint")` |

DO NOT ask "what were we working on?" — SEARCH FIRST.
If search returns 0 results, proceed as a fresh session.

## ctx commands

| Command | Action |
|---------|--------|
| `ctx stats` | Call `stats` MCP tool, display full output verbatim |
| `ctx doctor` | Call `doctor` MCP tool, run returned shell command, display as checklist |
| `ctx upgrade` | Call `upgrade` MCP tool, run returned shell command, display as checklist |
| `ctx purge` | Call `purge` MCP tool with confirm: true. Warns before wiping knowledge base. |

After /clear or /compact: knowledge base and session stats preserved. Use `ctx purge` to start fresh.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
