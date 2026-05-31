import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

/**
 * beads-rust — Pi extension for `br` (beads_rust) task tracking.
 *
 * Replaces pi-beads-extension (Python `bd` CLI) with native `br` support.
 * Handles: CLI detection, workspace state, slash commands, status bar,
 * session context injection, compaction preservation, and shared state
 * for the governance extension's edit-gate.
 */

// ─── Types ───────────────────────────────────────────────────────────

interface BrIssue {
  id: string;
  title: string;
  status: string;
  priority: number;
  issue_type?: string;
  assignee?: string;
  created_at?: string;
  updated_at?: string;
}

interface BeadsState {
  available: boolean;
  initialized: boolean;
  version?: string;
  beadsPath?: string;
  activeBeadIds: string[];
  activeBeads: BrIssue[];
  readyCount: number;
  checkedAt: number;
  contextAt: number;
}

interface BrExecResult {
  ok: boolean;
  stdout: string;
  stderr: string;
}

// ─── Constants ───────────────────────────────────────────────────────

const STATE_TTL_MS = 10_000;
const CONTEXT_TTL_MS = 15_000;

// Shared global for governance extension to read
const GLOBAL_KEY = "__beadsRustState";

// ─── Slash command aliases ───────────────────────────────────────────

const COMMANDS = [
  { name: "ready",          cmd: ["ready", "--json"],                         desc: "Show ready work (no blockers)" },
  { name: "list",           cmd: ["list", "--format", "json"],                desc: "List issues with optional filters" },
  { name: "show",           cmd: ["show"],                                    desc: "Show issue details" },
  { name: "create",         cmd: ["create"],                                  desc: "Create a new issue" },
  { name: "update",         cmd: ["update"],                                  desc: "Update an issue" },
  { name: "close",          cmd: ["close"],                                   desc: "Close an issue" },
  { name: "blocked",        cmd: ["blocked", "--json"],                       desc: "Show blocked work" },
  { name: "stats",          cmd: ["stats", "--format", "json"],               desc: "Project statistics" },
  { name: "dep",            cmd: ["dep"],                                     desc: "Manage dependencies" },
  { name: "search",         cmd: ["search"],                                  desc: "Search issues" },
  { name: "init",           cmd: ["init"],                                    desc: "Initialize beads in this project" },
  { name: "sync",           cmd: ["sync", "--flush-only"],                    desc: "Flush JSONL export" },
  { name: "guide",          cmd: ["robot-docs", "guide"],                     desc: "Agent workflow guide" },
  { name: "coordination",   cmd: ["coordination", "status", "--json"],        desc: "Swarm claim diagnostics" },
  { name: "scheduler",      cmd: ["scheduler", "--json"],                     desc: "Ranked ready work for agents" },
  { name: "version",        cmd: ["version", "--json"],                       desc: "br version info" },
] as const;

// ─── Extension ───────────────────────────────────────────────────────

export default function beadsRustExtension(pi: ExtensionAPI) {
  let state: BeadsState = createInitialState();

  function createInitialState(): BeadsState {
    return {
      available: false,
      initialized: false,
      activeBeadIds: [],
      activeBeads: [],
      readyCount: 0,
      checkedAt: 0,
      contextAt: 0,
    };
  }

  // ── CLI wrapper ──────────────────────────────────────────────────

  async function runBr(
    args: string[],
    cwd?: string,
    timeout = 15000,
  ): Promise<BrExecResult> {
    try {
      const result = await pi.exec("br", args, {
        timeout,
        // @ts-ignore — env override for suppressing Rust dep logs
        env: { RUST_LOG: "error" },
      });
      return {
        ok: result.code === 0,
        stdout: result.stdout?.trim() ?? "",
        stderr: result.stderr?.trim() ?? "",
      };
    } catch (error) {
      return {
        ok: false,
        stdout: "",
        stderr: error instanceof Error ? error.message : String(error),
      };
    }
  }

  function tryParseJson<T>(stdout: string): T | null {
    try {
      return JSON.parse(stdout) as T;
    } catch {
      return null;
    }
  }

  // ── State management ─────────────────────────────────────────────

  async function refreshState(force = false): Promise<BeadsState> {
    if (!force && Date.now() - state.checkedAt < STATE_TTL_MS) {
      return state;
    }

    // Check if br is available
    const ver = await runBr(["version", "--json"]);
    if (!ver.ok) {
      state = createInitialState();
      state.checkedAt = Date.now();
      publishState();
      return state;
    }

    const verData = tryParseJson<{ version?: string }>(ver.stdout);
    state.available = true;
    state.version = verData?.version;

    // Check workspace
    const where = await runBr(["where", "--json"]);
    state.initialized = where.ok;
    if (where.ok) {
      const whereData = tryParseJson<{ beads_dir?: string }>(where.stdout);
      state.beadsPath = whereData?.beads_dir;
    } else {
      state.beadsPath = undefined;
    }

    // Get in-progress beads
    if (state.initialized) {
      const inProgress = await runBr([
        "list", "--status", "in_progress", "--format", "json",
      ]);
      if (inProgress.ok) {
        const data = tryParseJson<{ issues?: BrIssue[] }>(inProgress.stdout);
        const issues = data?.issues ?? [];
        state.activeBeads = issues;
        state.activeBeadIds = issues.map((b) => b.id).filter(Boolean);
      }

      const ready = await runBr(["ready", "--json"]);
      if (ready.ok) {
        const readyIssues = tryParseJson<BrIssue[]>(ready.stdout);
        state.readyCount = Array.isArray(readyIssues) ? readyIssues.length : 0;
      }
    } else {
      state.activeBeads = [];
      state.activeBeadIds = [];
      state.readyCount = 0;
    }

    state.checkedAt = Date.now();
    publishState();
    return state;
  }

  /**
   * Build session context for system prompt + compaction.
   * Replaces `bd prime` with a composite of br outputs.
   */
  async function getSessionContext(): Promise<string | undefined> {
    await refreshState();
    if (!state.available || !state.initialized) return undefined;

    if (Date.now() - state.contextAt < CONTEXT_TTL_MS) {
      return undefined; // Caller should use cached state
    }

    const parts: string[] = [];

    // Active beads
    if (state.activeBeads.length > 0) {
      parts.push("### In-Progress Beads");
      for (const b of state.activeBeads) {
        const assignee = b.assignee ? ` (${b.assignee})` : "";
        parts.push(`- **${b.id}**: ${b.title}${assignee}`);
      }
    }

    // Ready work count
    if (state.readyCount > 0) {
      parts.push(`\n### Ready Work\n${state.readyCount} issue(s) ready to claim.`);
    }

    // Coordination status (stale claims, collisions)
    const coord = await runBr(["coordination", "status", "--json"]);
    if (coord.ok) {
      const coordData = tryParseJson<{
        summary?: { stale_candidate?: number; collision_risk?: number };
      }>(coord.stdout);
      const stale = coordData?.summary?.stale_candidate ?? 0;
      const collisions = coordData?.summary?.collision_risk ?? 0;
      if (stale > 0 || collisions > 0) {
        parts.push(`\n### ⚠️ Coordination Warnings`);
        if (stale > 0) parts.push(`- ${stale} stale claim(s) — consider force-release`);
        if (collisions > 0) parts.push(`- ${collisions} collision risk(s)`);
      }
    }

    state.contextAt = Date.now();
    return parts.length > 0 ? parts.join("\n") : undefined;
  }

  /** Publish state to globalThis for governance extension */
  function publishState(): void {
    (globalThis as Record<string, unknown>)[GLOBAL_KEY] = {
      available: state.available,
      initialized: state.initialized,
      activeBeadIds: [...state.activeBeadIds],
      checkedAt: state.checkedAt,
    };
  }

  // ── Status bar ───────────────────────────────────────────────────

  function syncStatusBar(ctx: { ui: { setStatus: (id: string, text: string | undefined) => void } }) {
    if (!state.available) {
      ctx.ui.setStatus("beads", undefined);
      return;
    }

    if (!state.initialized) {
      ctx.ui.setStatus("beads", "beads: init needed");
      return;
    }

    const parts: string[] = ["beads"];
    if (state.activeBeadIds.length > 0) {
      parts.push(`${state.activeBeadIds.length} active`);
    }
    if (state.readyCount > 0) {
      parts.push(`${state.readyCount} ready`);
    }
    ctx.ui.setStatus("beads", parts.join(" | "));
  }

  // ── Slash commands ───────────────────────────────────────────────

  for (const command of COMMANDS) {
    pi.registerCommand(`br:${command.name}`, {
      description: command.desc,
      handler: async (args) => {
        const suffix = args?.trim() ?? "";
        // Build the br command as a bash invocation
        const fullCmd = ["RUST_LOG=error", "br", ...command.cmd];
        if (suffix) fullCmd.push(suffix);
        pi.sendUserMessage(`!${fullCmd.join(" ")}`);
      },
    });
  }

  // Bare /br → guide
  pi.registerCommand("br", {
    description: "Show br workflow guide",
    handler: async () => {
      pi.sendUserMessage("!RUST_LOG=error br robot-docs guide");
    },
  });

  // ── Session lifecycle ────────────────────────────────────────────

  pi.on("session_start", async (_event, ctx) => {
    state = createInitialState();
    await refreshState(true);
    syncStatusBar(ctx);

    if (!state.available) {
      ctx.ui.notify(
        "br (beads_rust) not found. Install br to enable /br:* workflows.",
        "warning",
      );
      return;
    }

    if (!state.initialized) {
      ctx.ui.notify(
        "br available but not initialized. Run /br:init to enable tracking.",
        "info",
      );
    }
  });

  pi.on("agent_end", async (_event, ctx) => {
    await refreshState(true);
    syncStatusBar(ctx);
  });

  // Watch for br mutations to refresh state
  pi.on("tool_result", async (event, ctx) => {
    if (event.toolName !== "bash") return;
    const command =
      (event.input as Record<string, unknown>)?.command as string ?? "";

    if (/\bbr\s+(create|update|close|reopen|init|dep|delete)\b/.test(command)) {
      if (!event.isError) {
        await refreshState(true);
        syncStatusBar(ctx);
      }
    }
  });

  // ── System prompt injection ──────────────────────────────────────

  pi.on("before_agent_start", async (event, ctx) => {
    await refreshState();
    syncStatusBar(ctx);

    if (!state.available) return;

    const baseInstructions = `
## Beads Task Tracking

- Use \`br\` (beads_rust) for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists.
- \`br\` has no \`prime\` or \`remember\` subcommands. Store durable knowledge as bead comments, descriptions, follow-up beads, or Agent Mail threads.
- \`br\` is non-invasive: it never commits, pushes, pulls, installs hooks, or runs as a background service.
- Mutations auto-flush JSONL; run \`br sync --flush-only\` as a final check before committing.
- Suppress noisy logs: prefix with \`RUST_LOG=error br ...\`

### Read commands
- \`br ready --json\` — available work (open, unblocked)
- \`br list --format json\` — list with filters (\`--status\`, \`--priority\`, \`--assignee\`)
- \`br show <id> --json\` — full issue details
- \`br blocked --json\` — blocked work
- \`br stats --format json\` — project statistics
- \`br coordination status --json\` — swarm claim diagnostics
- \`br scheduler --json\` — ranked work recommendations

### Write commands
- \`br create "title" --json\` — create issue
- \`br update <id> --claim --actor "$AGENT_NAME" --json\` — claim work
- \`br update <id> --status in_progress --json\` — change status
- \`br close <id> --reason "..." --json\` — close issue
- \`br dep add <issue> <dep> --type blocks --json\` — add dependency
- \`br comments add <id> --message "..." --json\` — add comment
- \`br sync --flush-only\` — ensure JSONL export current

### Slash commands
Use \`/br:ready\`, \`/br:create\`, \`/br:show\`, etc. for quick access.
`;

    if (!state.initialized) {
      // Only inject if prompt mentions task-related words
      if (
        !/\b(beads|br\b|task|todo|issue|tracker|backlog|plan)\b/i.test(
          event.prompt,
        )
      ) {
        return;
      }

      return {
        systemPrompt:
          event.systemPrompt +
          baseInstructions +
          "\nBeads (br) is installed but not initialized. Suggest `/br:init` if the user wants tracking here.\n",
      };
    }

    // Build session context
    const sessionContext = await getSessionContext();
    const contextSection = sessionContext
      ? `\n### Current Beads Context\n\n${sessionContext}\n`
      : "\n### Current Beads Context\n\nBeads initialized. No active context.\n";

    return {
      systemPrompt: event.systemPrompt + baseInstructions + contextSection,
    };
  });

  // ── Compaction hook ──────────────────────────────────────────────
  //
  // Inject active beads context into compaction instructions so the
  // LLM preserves task state across compaction boundaries.

  pi.on("session_before_compact", async (event, ctx) => {
    await refreshState();

    if (!state.available || !state.initialized) return;

    const sessionContext = await getSessionContext();
    if (!sessionContext) return;

    const beadsBlock = [
      "Beads (br) is active. Preserve task-tracking state, issue IDs,",
      "dependency relationships, and next-step cues. Current state:",
      "",
      "<beads-context>",
      sessionContext,
      "</beads-context>",
    ].join("\n");

    const existing = event.customInstructions?.trim();
    const customInstructions = existing
      ? `${existing}\n\n${beadsBlock}`
      : beadsBlock;

    // Let Pi handle the compaction with our enriched instructions
    // (don't override the compaction itself — pi-agenticoding handoff
    // or built-in compaction handles the actual summary)
    return { customInstructions };
  });

  pi.on("session_compact", async (_event, ctx) => {
    await refreshState(true);
    syncStatusBar(ctx);
  });
}
