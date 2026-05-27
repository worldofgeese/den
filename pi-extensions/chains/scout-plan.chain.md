---
name: scout-plan
description: Gather codebase context then create an implementation plan with agreed skill-routing policy
---

## scout
output: context.md

Analyze the codebase for {task}. Ground in existing patterns, map integration points, identify files that will need changes.

Apply agreed scout skills when triggered: context-mode, ce-sessions, ce-brainstorm, ce-ideate, ce-strategy, operational-integration-audit. Surface any ask-user decision gates to the parent. Do not use approved skip skills.

## planner
reads: context.md
output: plan.md
progress: true

Create an implementation plan based on the context gathered:

{previous}

Include a `Skill routing` section and plan verification for operational integration, browser/manual QA when UI-visible, agent-native parity when agent/prompt/tool/subagent/chain surfaces are involved, and end-of-workstream `workstream-compounder` capture when durable learning is likely.
