**Research value: high** — Three upstream repos expose clear, test-backed API surfaces; pi-subagents is full orchestration stack, elpapi42 extensions are deliberate subsets.

## Executive comparison

| Capability | [pi-subagents](https://github.com/nicobailon/pi-subagents) | [pi-fork](https://github.com/elpapi42/pi-fork) | [pi-minimal-subagent](https://github.com/elpapi42/pi-minimal-subagent) |
|------------|-----------------------------------------------------------|------------------------------------------------|------------------------------------------------------------------------|
| Custom named agents | Yes — `.md` agents, builtins, `agentOverrides`, runtime `action: create/update` | **No** — one `fork({ task, effort? })` tool only | **Partial** — `.md` agents (`name`, `description`, `model`, `extensions`, `skills`, `thinking`) |
| Chains | Yes — `.chain.md`, `.chain.json`, dynamic fanout, `{previous}`/`{outputs.*}`, slash `/chain` | **No** | **No** (README explicit) |
| Parallel fanout | Yes — `tasks[]`, chain parallel groups, concurrency/failFast/worktree | **Partial** — parent calls `fork` multiple times per turn (no first-class API) | **Partial** — parent calls `subagent` multiple times per turn |
| Context fresh / fork | Yes — `context: "fresh" \| "fork"`, per-agent `defaultContext`, real branched sessions | **Fork-only** — temp JSONL snapshot of active branch (not named subagent personas) | **Fresh-only** — `pi --no-session` subprocess; zero parent conversation inherit |
| Saved outputs / artifacts | Yes — chain dirs, `output`/`outputMode`, acceptance gates, `artifacts` flag | **Partial** — structured `Result`/`Output`/`Evidence`/`Learnings` in tool result; cost footer | **Partial** — debug `stdout.jsonl` / `stderr.log` under temp dir only |
| Async / resume / status | Yes — `async`, `action: status/interrupt/resume`, widgets, notifications | **No** — sync foreground subprocess | **No** — sync foreground subprocess |
| Model routing | Yes — `agentOverrides`, `fallbackModels`, per-step `model`, thinking | **Partial** — `effortProfiles` → `--provider`/`--model`/`--thinking` on child | **Partial** — agent frontmatter + global `pi-minimal-subagent.model` |
| Intercom / session coordination | Yes — optional `pi-intercom` bridge, `contact_supervisor`, grouped completion delivery | **No** | **No** |
| Tool / skill constraints | Yes — agent `tools`, overrides, child-safe fanout, MCP allowlist, recursion depth | **Partial** — child gets Pi default tools; `extensions` tri-state on children | **Partial** — skills via `--skill`; **no** `tools` frontmatter (README explicit) |

**Bottom line:** Neither elpapi42 extension replicates pi-subagents orchestration. **pi-fork** ≈ branch-aware context offload + parallelism. **pi-minimal-subagent** ≈ named isolated workers. Together they still lack chains, async lifecycle, intercom, per-agent tool policy, and saved workflow machinery.

---

## Prior art

### pi-subagents (canonical orchestration)

- **Package:** `npm:pi-subagents` (registry ~0.27.0, May 2026); ~2K GitHub stars; pi.dev catalog entry.
- **Tool:** `subagent` with modes `single`, `tasks[]` (parallel), `chain[]`, plus management `action: list|get|create|update|delete`.
- **Agents:** Builtin set (`scout`, `researcher`, `planner`, `worker`, `reviewer`, `oracle`, …) + user/project `.md`; `subagents.agentOverrides` for model, thinking, `fallbackModels`, tools, skills, prompt.
- **Chains:** Saved `.chain.md` / `.chain.json`; dynamic fanout via structured `expand` + `collect`; TUI clarify; templates `{previous}`, `{chain_dir}`, `{outputs.name}`.
- **Fork context:** `context: "fork"` uses persisted parent session + `createBranchedSession` — fails fast if parent not persisted ([`fork-context.ts`](https://github.com/nicobailon/pi-subagents/blob/main/src/shared/fork-context.ts)).
- **Async:** Background runs, `subagent({ action: "status" })`, `interrupt`, `resume` (live intercom or revive from child `.jsonl`), `asyncByDefault`, `forceTopLevelAsync` ([README](https://github.com/nicobailon/pi-subagents/blob/main/README.md)).
- **Intercom:** Optional `npm:pi-intercom`; bridge injects `contact_supervisor` / `intercom` into child allowlist; modes `always` | `fork-only` | `off` ([`intercom-bridge.ts`](https://github.com/nicobailon/pi-subagents/blob/main/src/intercom/intercom-bridge.ts)).
- **Child safety:** Children drop parent orchestration artifacts; `subagent` tool only if agent `tools` includes it; `maxSubagentDepth`.

### pi-fork (context management + parallelism)

- **Install:** `pi install git:github.com/elpapi42/pi-fork` (git-only on pi.dev catalog at research time; not listed as npm package in search).
- **Tool:** Single `fork({ task, effort?: fast|balanced|deep })` — no agent registry ([`src/index.ts`](https://github.com/elpapi42/pi-fork/blob/main/src/index.ts)).
- **Context:** Snapshots `getHeader()` + `getBranch()` into temp JSONL; child inherits **active branch only** (siblings/abandoned branches excluded). Does **not** use agent markdown or append role personas.
- **Output contract:** User-message instructions require four sections: Result, Output, Evidence, Learnings ([README](https://github.com/elpapi42/pi-fork/blob/main/README.md)).
- **Model routing:** `pi-fork.effortProfiles` maps effort → provider/id/thinking; missing profile → child Pi defaults + warning.
- **Child extensions:** Same tri-state `extensions` as minimal-subagent (`null` / `[]` / explicit list); `offline` defaults true (`PI_OFFLINE=1`).
- **Cost:** Session footer `forks +$X.XXX` from completed fork tool usage.
- **Parallelism:** Documented as “parallel child agents” via multiple fork invocations; no chain/orchestrator/pool types.
- **In-process roadmap:** [`IN_PROCESS_RUNTIME_PROPOSAL.md`](https://github.com/elpapi42/pi-fork/blob/main/IN_PROCESS_RUNTIME_PROPOSAL.md) — future `AgentSession` runner; env/offline may stay subprocess-only.

### pi-minimal-subagent (minimal named workers)

- **Install:** `pi install git:github.com/elpapi42/pi-minimal-subagent`.
- **Tool:** `subagent({ agent, task })` only ([`src/index.ts`](https://github.com/elpapi42/pi-minimal-subagent/blob/main/src/index.ts)).
- **Explicit non-features:** “no built-in parallel, chain, pool, or orchestrator modes” — parallel = multiple tool calls same turn ([README](https://github.com/elpapi42/pi-minimal-subagent/blob/main/README.md)).
- **Context:** `pi --mode json -p --no-session` + optional `--append-system-prompt` from agent body — **isolated**, not forked from parent session ([`runner.ts`](https://github.com/elpapi42/pi-minimal-subagent/blob/main/src/runner.ts)).
- **Artifacts:** Temp dir with `stdout.jsonl`, `stderr.log` for diagnostics — not chain workflow outputs.
- **Settings:** `pi-minimal-subagent.model`, `extensions` (tri-state, matches pi-fork), `environment` merge (global ← project).
- **Tools:** “does not read `tools` frontmatter and does not pass `--tools`” — extra tools only via extensions.
- **Recursion:** Not blocked — extension in child → nested `subagent` allowed (unlike pi-subagents child-safe defaults).

---

## Adjacent solutions

| Project | Overlap | Gap vs pi-subagents |
|---------|---------|---------------------|
| [@mjakl/pi-subagent](https://github.com/mjakl/pi-subagent) | `spawn` / `fork` context modes | Trims chains, scope selectors — “simpler fork” |
| [markhougaard/pi-subagent](https://github.com/markhougaard/pi-subagent) | Minimal `subagent` + markdown roles | Same parallel-via-concurrent-calls pattern as minimal-subagent |
| [tuansondinh/pi-fast-subagent](https://github.com/tuansondinh/pi-fast-subagent) | In-process, `background` + poll | Different runtime; not full chain/intercom stack |
| [tintinweb/pi-subagents](https://pi.dev/packages/@tintinweb/pi-subagents) | Claude Code-style agents | Separate lineage from nicobailon/pi-subagents |

**Composition note:** pi-subagents already implements `context: "fork"` with real session branches. pi-fork’s JSONL snapshot is a **different** fork semantics (exploration offload, no agent identity). Using both may duplicate fork concepts.

---

## Market and competitor signals

- **pi.dev catalog:** `pi-subagents` is primary npm orchestration package (~18K weekly downloads per registry snippet). elpapi42 packages lean git-install; minimal-subagent documents parity with pi-fork’s `extensions` tri-state — shared author, complementary scope split (fork = branch context, minimal = named fresh workers).
- **Convergence:** Multiple subagent extensions agree on **OS subprocess isolation** + **parent-driven parallel tool calls** when no native parallel mode.
- **Differentiation:** nicobailon stack adds **workflow persistence** (chains), **background job UX**, and **intercom bridge** — enterprise/orchestrator features absent from elpapi42 minimal line.

---

## Cross-domain analogies

**MapReduce vs thread pool:** pi-subagents chains + dynamic fanout ≈ staged pipeline with reducers (`collect.as`); pi-fork/minimal ≈ fire parallel workers with hand-rolled merge in parent LLM context — no framework-level `{previous}` or structured fanout.

**Microservices vs fork bomb:** pi-minimal-subagent allows recursive extension loading in children (no orchestrator guard); pi-subagents enforces depth and strips parent-only tools — same “subprocess isolation” surface, different **trust boundary**.

---

## Feature replication matrix (can X replace pi-subagents for Y?)

| Feature | pi-fork alone | pi-minimal alone | fork + minimal | pi-subagents |
|---------|---------------|------------------|----------------|--------------|
| Named reviewer/scout/worker | No | Yes | Yes | Yes |
| Saved review pipeline chain | No | No | No* | Yes |
| Background implement + check later | No | No | No | Yes |
| Child asks parent mid-run | No | No | No | Yes (pi-intercom) |
| Per-agent tool allowlist | No | No | No | Yes |
| Fork parent conversation into child | Yes (snapshot) | No | Partial** | Yes (branch API) |
| Git worktree per parallel task | No | No | No | Yes |

\* Parent LLM could manually chain minimal `subagent` calls — no `.chain.md`, clarify UI, or `{outputs.*}` schema fanout.

\** fork gives branch context; minimal gives personas — still no unified status tree or async resume.

---

## Sources

| URL | Description |
|-----|-------------|
| https://github.com/nicobailon/pi-subagents | Full README: agents, chains, async, intercom, tool schema |
| https://github.com/nicobailon/pi-subagents/blob/main/src/shared/fork-context.ts | Branched-session fork implementation |
| https://github.com/nicobailon/pi-subagents/blob/main/src/intercom/intercom-bridge.ts | contact_supervisor / intercom bridge |
| https://github.com/nicobailon/pi-subagents/blob/main/src/extension/schemas.ts | TypeBox tool parameters (chain, async, actions) |
| https://registry.npmjs.org/pi-subagents | npm metadata, keywords, download signal |
| https://github.com/elpapi42/pi-fork | fork tool, effort profiles, branch snapshot semantics |
| https://github.com/elpapi42/pi-fork/blob/main/IN_PROCESS_RUNTIME_PROPOSAL.md | Planned in-process runtime |
| https://github.com/elpapi42/pi-minimal-subagent | Minimal subagent README + explicit non-features |
| https://github.com/elpapi42/pi-minimal-subagent/blob/main/src/runner.ts | `--no-session` spawn, artifact dirs |
| https://pi.dev/packages | Package catalog framing |

---

## Gaps

- **pi-fork npm publication** — Research found git install path; pi.dev catalog did not surface `pi-fork` as npm package (may be git-only).
- **Live compatibility** running fork + minimal-subagent + pi-subagents in one Pi settings.json — not tested; extension conflicts unknown.
- **pi-subagents post-0.27.0** — `main` may include fixes (e.g. PR #238 getFinalOutput) not yet on npm tag; capability set assumed from README + main tree at clone time (2026-06-02).
- **contact_supervisor in minimal/fork** — No upstream support; would require separate pi-intercom wiring by user, without pi-subagents bridge templates.
- **Exact parity of pi-fork snapshot vs pi-subagents `context:fork`** — Different code paths; behavioral equivalence for edge cases (compaction, hidden messages) not verified by integration test in this research pass.

**Suggested next steps:** If evaluating replacement: prototype one real workflow (e.g. `scout → planner → worker → parallel reviewers` with `--bg` + intercom) on minimal+fork and count manual parent prompts vs pi-subagents. If keeping pi-subagents: treat pi-fork as optional parent-context hygiene for main session only, not child orchestration substitute.
