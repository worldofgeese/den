---
name: review-fix
description: Review code changes, have worker fix accepted issues, re-review, then capture end-of-workstream learning when warranted
---

## reviewer
progress: true

Review the following changes with the expanded agreed review policy: correctness, maintainability, project standards, simplicity, operational integration, agent-native parity where applicable, and adversarial final pass. Enforce approved skill-routing and skip-list compliance.

Changes: {task}

## worker
progress: true

The reviewer found these issues. Fix the accepted issues only:

{previous}

Use ce-work, tdd, ce-debug, context-mode, operational-integration-audit, and ce-simplify-code when triggered. Add ce-frontend-design/ce-test-browser for UI-visible fixes and ce-agent-native-architecture for agent/prompt/tool/subagent/chain fixes. Do not use active-work skip skills.

## reviewer
progress: true

Re-review the worker's fixes. Confirm blockers are resolved and no new regressions were introduced:

{previous}

## workstream-compounder
output: compound-learning.md
progress: true

End-of-workstream learning capture. If this review/fix cycle produced durable reusable knowledge, capture it using ce-compound/ce-compound-refresh. If not, return `Skipped` with rationale. Prior step output:

{previous}
