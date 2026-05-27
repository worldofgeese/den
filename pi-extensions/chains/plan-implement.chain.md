---
name: plan-implement
description: Plan implementation, execute it, review it, then capture end-of-workstream learning when warranted
---

## planner
output: plan.md
progress: true

Create an implementation plan for: {task}

Include a `Skill routing` section. Apply agreed safe skills when triggered: ce-plan, ce-agent-native-architecture, ce-strategy, ce-optimize, adr, prd, plan-prd, operational-integration-audit, ce-sessions, ce-brainstorm, ce-ideate, ce-debug, tdd, ce-code-review, ce-doc-review, ce-frontend-design, ce-test-browser, ce-resolve-pr-feedback, ce-simplify-code, ce-work, ce-worktree, grill-me, agent-browser, librarian, context-mode. Escalate ask-user decisions to the parent.

Respect approved skips unless user re-authorizes them: ce-clean-gone-branches, ce-commit-push-pr, ce-compound during active work, ce-compound-refresh during active work, ce-demo-reel, ce-dhh-rails-style, ce-gemini-imagegen, ce-product-pulse, ce-proof, ce-riffrec-feedback-analysis, ce-slack-research, python as non-Python style skill, ctx-doctor, ctx-insight, ctx-purge, ctx-upgrade, ctx-stats.

## worker
reads: plan.md
progress: true

Implement the plan:

{previous}

Use the agreed implementation bundle when triggered: ce-work, tdd, ce-debug, context-mode, operational-integration-audit, ce-simplify-code; add ce-frontend-design and ce-test-browser/agent-browser for UI/browser-visible changes; add ce-agent-native-architecture for agent/prompt/tool/subagent/chain surfaces. Do not use active-work skip skills.

## reviewer
reads: plan.md
progress: true

Review the implementation against the plan and agreed skill-routing policy. The worker produced:

{previous}

Use the expanded ce-review chain dimensions: correctness, maintainability, project standards, simplicity, operational integration, agent-native parity, then adversarial.

## workstream-compounder
reads: plan.md, progress.md
output: compound-learning.md
progress: true

End-of-workstream learning capture. If this work produced durable reusable knowledge, capture it using ce-compound/ce-compound-refresh. If not, return `Skipped` with rationale. Prior step output:

{previous}
