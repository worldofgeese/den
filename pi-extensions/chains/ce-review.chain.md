---
name: ce-review
description: Run CE correctness, maintainability, and project-standards reviewers in parallel, then adversarial reviewer as final pass
---

## parallel
- ce-correctness-reviewer: Review this diff for logic errors, edge cases, state management bugs, error propagation failures, and intent-vs-implementation mismatches. Context: {previous}
- ce-maintainability-reviewer: Review this diff for premature abstraction, unnecessary indirection, dead code, coupling between unrelated modules, and naming that obscures intent. Context: {previous}
- ce-project-standards-reviewer: Audit this diff against the project's AGENTS.md and CLAUDE.md standards. Context: {previous}

## ce-adversarial-reviewer

The three reviewers above produced these findings:

{previous}

Now run your adversarial pass: actively construct failure scenarios to break the implementation. Focus on what the other reviewers missed — race conditions under load, malicious inputs, deployment edge cases, and assumptions that hold in dev but fail in production.
