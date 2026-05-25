---
name: plan-implement
description: Plan implementation, execute it, then review the result
---

## planner
output: plan.md
progress: true

Create an implementation plan for: {task}

## worker
reads: plan.md
progress: true

Implement the plan:

{previous}

## reviewer
reads: plan.md
progress: true

Review the implementation against the plan. The worker produced:

{previous}
