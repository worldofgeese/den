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
<!-- Hand-edited: switched from br to bd (2026-08-03). If a beads installer
     regenerates this block back to br guidance, re-apply this change. -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. `bd` is canonical for all Beads operations. If older guidance mentions `br`, treat it as stale and use `bd` instead.

Run `bd prime` for agent-focused workflow context and command guidance.

### Quick Reference

```bash
bd ready --json                         # Find available work
bd show <id> --json                     # View issue details
bd update <id> --claim                  # Claim work (assignee + in_progress)
bd close <id> --reason "Completed"      # Complete work
bd export --output .beads/issues.jsonl  # Refresh the JSONL export
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Use `bd remember "insight"` for durable project memory. Do NOT create MEMORY.md files
- `bd` has no `sync` subcommand — `bd export` is the JSONL flush path, and there is no `robot-docs`
- Git handoff is your responsibility: `bd` does not commit or push for you
- This repo runs embedded-Dolt mode (`.beads/embeddeddolt/`), where `bd doctor` is unsupported and exits with guidance instead of running checks
- `bd export` omits `source_repo` / `source_repo_path`, which the committed `.beads/issues.jsonl` carries on every issue. Do not commit an export that drops them — check `git diff .beads/issues.jsonl` before staging

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd export --output .beads/issues.jsonl
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
