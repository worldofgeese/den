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



<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:1105d646 -->
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

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
