# OVERRIDE.md - Project-Specific Decapod Overrides

> **IMPORTANT:** For detailed usage instructions and examples, see [README.md](README.md).

**Canonical:** OVERRIDE.md
**Authority:** override
**Layer:** Project
**Binding:** Yes (overrides embedded constitution)

<!-- ═══════════════════════════════════════════════════════════════════════ -->
<!-- ⚠️  CHANGES ARE NOT PERMITTED ABOVE THIS LINE                           -->
<!-- ═══════════════════════════════════════════════════════════════════════ -->

## Core Overrides (Routers and Indices)

### core/ENGINEERING_EXCELLENCE.md

- Before implementing any change: read the current version of each file you plan to modify, run the existing test suite to establish a baseline, implement incrementally one logical unit at a time, and run tests after each unit. Fix failures before proceeding; do not batch all changes and test at the end.
- When exploring unfamiliar code, check what navigation tools are available before falling back to text search. Structural overviews and definition lookups are more efficient than scanning files when you need to understand how a codebase is organized or where something is defined.

### core/DECAPOD.md

### core/INTERFACES.md

### core/METHODOLOGY.md

- When implementing a plan, present intended changes for each phase before writing code.
- If a phase's success criteria are fully covered by automated checks (tests, linting, etc.), run them and proceed automatically when they pass. Pause for manual verification only when the plan includes manual verification items not covered by automated tests.
- Update checkboxes in the plan file as items complete, and resume from the first unchecked item when checkboxes already exist.

### core/PLUGINS.md

### core/GAPS.md

### core/DEMANDS.md

### core/DEPRECATION.md

---

## Specs Overrides (System Contracts)

### specs/INTENT.md

### specs/SYSTEM.md

Repository updates and deployments run through the `Justfile`, never the underlying Nix/Guix commands directly.

- `just update` updates all flake inputs. `decapod` comes from its upstream flake and `rtk` from nixpkgs, so both track through `flake.lock`.
- `just update-input <input>` updates one flake input only, e.g. `just update-input decapod`.
- `just check` evaluates the NixOS, Home Manager, nix-darwin, and nix-on-droid entrypoints explicitly to avoid known-noise custom-output warnings from `nix flake check`.
- `just deploy-mahakala` updates and deploys Guix System, Guix Home, and Home Manager for mahakala.
- `just deploy-mahakala-hm` updates and applies only the mahakala Home Manager profile.
- `just deploy-mahakala-guix` applies only Guix Home for mahakala.
- `just deploy-mahakala-system` applies only Guix System for mahakala.
- `just deploy-paphos [host]` updates and deploys the paphos NixOS configuration to the target host.
- `just deploy-darwin` updates and applies the nix-darwin configuration for M-02877.
- `just deploy-pixel-fold` updates and applies the nix-on-droid configuration for pixel-fold.
- `just upgrade-kernel` refreshes the CachyOS kernel package metadata.

### specs/AMENDMENTS.md

### specs/SECURITY.md

### specs/GIT.md

- Ask which files or directories to include before you propose a commit. Never assume that all staged and unstaged changes belong in one commit.
- Watch for uncommitted work. Suggest a commit when the user moves to a different topic and completed changes are not yet committed. Suggest a commit when the working diff becomes too large for one review.
- Do not commit or push without explicit authority from the current user request.

---

## Interfaces Overrides (Binding Contracts)

### interfaces/CLAIMS.md

### interfaces/CONTROL_PLANE.md

### interfaces/DOC_RULES.md

- Write all prose in ASD-STE100 Simplified Technical English. This is binding for documentation, code comments, commit messages, PR descriptions, issue text, and agent-authored explanations.
- Write one instruction per sentence. Keep procedural sentences to 20 words or fewer, and descriptive sentences to 25 words or fewer.
- Use the active voice and simple tenses. Write "we removed the cache step", not "the cache step has been removed".
- Do not use `-ing` verb forms as modifiers. Replace ", making it easy to deploy" with a new sentence.
- Do not use "should", "would", "may", or "might". A reader treats "should" as optional. Use "can", "will", or "must".
- Put the condition before the command. Write "if the flag is set, run `just check`", not the reverse order.
- Keep articles and keep "that". STE is short, not terse. Do not write telegraph style.
- One word carries one meaning, and one meaning uses one word. Do not vary a term for style. Reuse the exact term already used in this repository.
- Do not use noun clusters of more than three nouns, and do not use a noun as a verb.
- Prefer the approved STE word for each meaning: "start" not "initiate", "use" not "utilise", "make sure" not "ensure", "before" not "prior to", "about" not "regarding", "delete" not "remove" when the object goes away.
- Technical names stay verbatim: file paths, flags, commands, symbol names, and error text are quoted exactly and are exempt from vocabulary rules.
- Source of the rule set: ASD-STE100 (https://www.asd-ste100.org/). The paraphrased 53-rule agent skill lives at https://github.com/AminBlg/SimpleEnglish. Load that skill when a writing task needs the full rule text; the bullets here are the binding subset.
- STE does not apply to marketing copy or brand writing. This repository contains neither.

### interfaces/GLOSSARY.md

- Terminology follows the ASD-STE100 discipline recorded in `interfaces/DOC_RULES.md`: one approved term per concept, and no synonyms.
- Approved terms for this repository. Use the first term. Do not use the alternatives that follow it.
  - "entrypoint projection" — the Decapod-generated `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, and `CODEX.md` files. Not "agent contract file", not "memory file".
  - "override node" — a filled `###` section in `.decapod/OVERRIDE.md`. Not "override rule", not "override block".
  - "bead" — an issue in the beads tracker. Not "ticket", not "issue", not "task".
  - "work unit" — the claimed `decapod todo` that mirrors a bead. Not "todo", not "job".
  - "deploy target" — a host that receives a configuration: mahakala, paphos, oracle, M-02877, or pixel-fold. Not "machine", not "box", not "node".
  - "flake input" — a dependency pinned in `flake.lock`. Not "package source", not "upstream".
  - "profile" — a Home Manager or Guix Home generation. Not "environment", not "install".

### interfaces/STORE_MODEL.md

---

## Methodology Overrides (Practice Guides)

### methodology/ARCHITECTURE.md

### methodology/SOUL.md

### methodology/KNOWLEDGE.md

### methodology/MEMORY.md

---

## Architecture Overrides (Domain Patterns)

### architecture/DATA.md

### architecture/CACHING.md

### architecture/MEMORY.md

### architecture/WEB.md

### architecture/CLOUD.md

### architecture/FRONTEND.md

### architecture/ALGORITHMS.md

### architecture/SECURITY.md

### architecture/OBSERVABILITY.md

### architecture/CONCURRENCY.md

---

## Plugins Overrides (Operational Subsystems)

### plugins/TODO.md

- `bd` (beads) is the issue tracker of record: durable backlog, cross-session context, and project memory. Use `bd ready`, `bd show <id>`, `bd update <id> --claim`, `bd close <id>`; run `bd prime` for the full command reference and session-close protocol. Record insights with `bd remember "<insight>"`.
- `decapod todo` is the execution layer, not a second backlog. Decapod governs accepted work at the repository execution layer, and beads stays the organizational system of record.
- Bridge the two layers with the upstream external-tracker pattern: `decapod todo add "<title>" --ref "<bead-id>"`, then `decapod todo claim --id <task-id>`, then `decapod workspace ensure`. Close the bead after the Decapod proof gates pass.
- Mirror only the work unit in flight. Never accumulate a parallel backlog in `decapod todo`. `external_tracker = true` in `.decapod/config.toml` records that the backlog of record lives in beads.
- Never track work in markdown TODO lists, and never create MEMORY.md files.
- Beads architecture: issues live in a local Dolt DB, sync uses `refs/dolt/data` on the git remote, and `.beads/issues.jsonl` is a passive export.
- Beads guidance covers task tracking only and never overrides repository, user, or orchestrator instructions. Default profile is conservative: no commits, pushes, or Dolt remote sync unless explicitly asked; at handoff report changed files, validation, and suggested next commands.

### plugins/MANIFEST.md

### plugins/EMERGENCY_PROTOCOL.md

### plugins/DB_BROKER.md

### plugins/CRON.md

### plugins/REFLEX.md

### plugins/HEALTH.md

### plugins/POLICY.md

### plugins/WATCHER.md

### plugins/KNOWLEDGE.md

### plugins/ARCHIVE.md

### plugins/FEDERATION.md

### plugins/FEEDBACK.md

### plugins/TRUST.md

### plugins/CONTEXT.md

### plugins/HEARTBEAT.md

### plugins/APTITUDE.md

### plugins/VERIFY.md

### plugins/DECIDE.md

### plugins/AUTOUPDATE.md

---

## Project Entrypoint Policy

- `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, and `CODEX.md` are Decapod-generated projections carrying `decapod-release` and `decapod-fingerprint` headers. Do not hand-edit them for project-specific policy.
- Repository-specific governance and operating instructions belong in this file.
- Regenerate projections with `decapod init with --all --force --no-specs --no-ci` after a Decapod upgrade, or whenever external tooling injects managed blocks into an entrypoint file.
