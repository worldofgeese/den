---
name: scout-plan
description: Gather codebase context then create an implementation plan
---

## scout
output: context.md

Analyze the codebase for {task}. Ground in existing patterns, map integration points, identify files that will need changes.

## planner
reads: context.md
output: plan.md
progress: true

Create an implementation plan based on the context gathered:

{previous}
