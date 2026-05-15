# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

This project follows Spec-Driven Development (SDD). Behavioral specs live in `.rpi/specs/` and serve as the source of truth for expected behavior. Always consult relevant specs before implementing or modifying features.

<!-- TODO: Add brief project description -->

## Git Workflow 

When committing changes, always ask the user which files/directories to include before proposing commits. Never assume all unstaged/staged changes should be committed.
Watch for uncommitted work that should be preserved. Suggest a commit (via `/rpi-commit`) when the user moves on to a different topic with completed changes still uncommitted, or when the working diff grows large enough that it risks becoming hard to review as a single commit.

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
- **Diagnose** (`/rpi-diagnose`): Iterative root-cause analysis and fix for complex bugs. Optional.
- **Explain** (`/rpi-explain`): Diff-scoped walkthrough of an implemented solution. Optional.

Each command suggests the next step. Start with `/rpi-propose` for features, `/rpi-plan` for bug fixes, `/rpi-diagnose` for complex bugs, `/rpi-research` when exploring.

## Codebase Navigation

When exploring unfamiliar code, check what navigation tools are available before falling back to text search. Structural overviews and definition lookups are more efficient than scanning files when you need to understand how a codebase is organized or where something is defined.

## Development Conventions

Before implementing any changes, always: 1) Read the current version of each file you plan to modify, 2) Run the existing test suite to establish a baseline, 3) Implement changes incrementally — one logical unit at a time, 4) Run tests after each unit. If tests fail, fix before proceeding. Do not batch all changes and test at the end.
<!-- TODO: Add project-specific conventions -->

When implementing a plan from `.rpi/plans/`, present intended changes for each phase before writing code. If a phase's success criteria are fully covered by automated checks (tests, linting, etc.), run them and proceed automatically when they pass. Only pause for manual verification when the plan includes manual verification items not covered by automated tests. Update checkboxes in the plan file as items complete, and resume from the first unchecked item if checkboxes already exist.

