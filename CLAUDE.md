# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

This is a Decapod-managed repository. See `AGENTS.md` for the universal agent contract.

> **Legacy note:** Earlier versions of this file referenced a `.rpi/` artifacts directory and `/rpi-*` commands (Spec-Driven Development pipeline). These are superseded by `AGENTS.md` and the `.decapod/` governance paths. Ignore any `.rpi/` or `/rpi-*` references as stale.

## Git Workflow

When committing changes, always ask the user which files/directories to include before proposing commits. Never assume all unstaged/staged changes should be committed.
Watch for uncommitted work that should be preserved. Suggest a commit when the user moves on to a different topic with completed changes still uncommitted, or when the working diff grows large enough that it risks becoming hard to review as a single commit.

## Codebase Navigation

When exploring unfamiliar code, check what navigation tools are available before falling back to text search. Structural overviews and definition lookups are more efficient than scanning files when you need to understand how a codebase is organized or where something is defined.

## Development Conventions

Before implementing any changes, always: 1) Read the current version of each file you plan to modify, 2) Run the existing test suite to establish a baseline, 3) Implement changes incrementally — one logical unit at a time, 4) Run tests after each unit. If tests fail, fix before proceeding. Do not batch all changes and test at the end.

When implementing a plan, present intended changes for each phase before writing code. If a phase's success criteria are fully covered by automated checks (tests, linting, etc.), run them and proceed automatically when they pass. Only pause for manual verification when the plan includes manual verification items not covered by automated tests. Update checkboxes in the plan file as items complete, and resume from the first unchecked item if checkboxes already exist.



<!-- BEGIN BEADS INTEGRATION v:2 profile:br-agent-mail -->
## Beads Issue Tracker

This project uses **br (Beads Rust)** for issue tracking. `br` is canonical for all Beads operations. If older guidance mentions `bd`, treat it as stale and use `br` instead.

Run `br robot-docs guide` for agent-focused command guidance. Prefer `RUST_LOG=error br ...` to suppress noisy Rust dependency logs while preserving normal stdout/JSON output.

### Quick Reference

```bash
br ready --json                         # Find available work
br show <id> --json                      # View issue details
br update <id> --status in_progress      # Mark work in progress
br close <id> --reason "Completed"        # Complete work
br sync --flush-only                     # Ensure JSONL export is current
```

### Rules

- Use `br` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- `br` has no `prime` or `remember` subcommands. Use `br robot-docs guide` for command guidance; store durable knowledge as Bead comments, Bead descriptions, follow-up Beads, or Agent Mail threads. Do NOT use MEMORY.md files
- `br` is non-invasive: it never commits, pushes, pulls, installs hooks, or runs as a background service. Git handoff is your responsibility
- `br` mutations auto-flush JSONL by default; still run `br sync --flush-only` as a final export check before committing/pushing

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   br sync --flush-only
   git status --short  # .beads changes must be committed before push
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
