---
name: ce-review
description: Run CE correctness, maintainability, and project-standards reviewers in parallel, then adversarial reviewer as final pass
---

## parallel
- ce-correctness-reviewer: Review this diff for logic errors, edge cases, state management bugs, error propagation failures, and intent-vs-implementation mismatches. Context: {previous}
- ce-maintainability-reviewer: Review this diff for premature abstraction, unnecessary indirection, dead code, coupling between unrelated modules, and naming that obscures intent. Context: {previous}
- ce-project-standards-reviewer: Audit this diff against the project's AGENTS.md/CLAUDE.md standards, Beads/Decapod obligations, deployment/sync obligations, and agreed skill-routing policy. Approved skip set unless re-authorized: ce-clean-gone-branches, ce-commit-push-pr, ce-compound during active work, ce-compound-refresh during active work, ce-demo-reel, ce-dhh-rails-style, ce-gemini-imagegen, ce-product-pulse, ce-proof, ce-riffrec-feedback-analysis, ce-slack-research, python as non-Python style skill, ctx-doctor, ctx-insight, ctx-purge, ctx-upgrade, ctx-stats. Context: {previous}

## ce-adversarial-reviewer

The parallel reviewers above produced these findings:

{previous}

Now run your adversarial pass: actively construct failure scenarios to break the implementation. Focus on what the other reviewers missed — race conditions under load, malicious inputs, deployment edge cases, assumptions that hold in dev but fail in production, stale server/deployment artifacts, and decision-drift against approved ADRs or skill-routing policy.
