import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync, appendFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Governance extension — deterministic enforcement of AGENTS.md rules.
 *
 * Rules enforced:
 *   1. Orchestrator must not do implementation work (edit gate)
 *   2. Decapod auto-init in any git repo; .decapod/ gitignored by default
 *   3. Block git add of .decapod/ and AGENTS.md unless user authorizes
 *   4. Beads tracking required before implementation (edit/write gate)
 *   5. Unpushed commits warning at session shutdown
 *   6. Context injection: active beads, decapod status
 */
export default function (pi: ExtensionAPI) {
  const isOrchestrator = process.env.SUBAGENT_CHILD_ENV !== "1";

  // ─── Beads state tracking ──────────────────────────────────────────
  //
  // Track whether any bead has been claimed in this session.
  // Reset on session start. Updated by watching br CLI calls.

  let beadClaimedThisSession = false;
  let beadCheckDone = false;
  let activeBeadIds: string[] = [];

  async function refreshBeadsState(): Promise<void> {
    try {
      const result = await pi.exec(
        "br",
        ["list", "--status", "in_progress", "--json"],
        { timeout: 5000 },
      );
      if (result.code === 0 && result.stdout?.trim()) {
        try {
          const beads = JSON.parse(result.stdout);
          if (Array.isArray(beads) && beads.length > 0) {
            beadClaimedThisSession = true;
            activeBeadIds = beads.map(
              (b: Record<string, unknown>) => b.id as string,
            ).filter(Boolean);
          }
        } catch {
          // Parse failed — might not be JSON array
        }
      }
      beadCheckDone = true;
    } catch {
      // br not installed or not a beads repo — skip
      beadCheckDone = true;
    }
  }

  // Reset state on session start and check for existing in-progress beads
  pi.on("session_start", async (_event, _ctx) => {
    beadClaimedThisSession = false;
    beadCheckDone = false;
    activeBeadIds = [];
    await refreshBeadsState();
  });

  // Watch for br create/claim calls to update state
  pi.on("tool_result", async (event, _ctx) => {
    if (event.toolName !== "bash") return;
    const command =
      (event.input as Record<string, unknown>)?.command as string || "";

    // Detect bead creation or claiming
    if (
      /\bbr\s+(create|update\s+.*--claim|update\s+.*--status\s+in_progress)/.test(
        command,
      )
    ) {
      if (!event.isError) {
        beadClaimedThisSession = true;
        // Refresh to get the actual bead IDs
        await refreshBeadsState();
      }
    }
  });

  // ─── Rule 1: Orchestrator edit gate ────────────────────────────────

  if (isOrchestrator) {
    pi.on("tool_call", async (event, ctx) => {
      if (event.toolName !== "edit") return;

      const path =
        (event.input as Record<string, unknown>)?.path as string || "unknown";

      const shouldDelegate = await ctx.ui.confirm(
        "🛡️ Orchestrator Edit Guard",
        [
          "AGENTS.md: orchestrator must not do implementation work directly.",
          "",
          `Attempting to edit: ${path}`,
          "",
          "Yes = block this edit (delegate to worker subagent)",
          "No  = allow this edit (override governance)",
        ].join("\n"),
      );

      if (shouldDelegate) {
        return {
          block: true,
          reason: [
            "Blocked by governance extension.",
            "Dispatch implementation to a worker subagent:",
            '  subagent({ agent: "worker", task: "..." })',
          ].join("\n"),
        };
      }
    });
  }

  // ─── Rule 2: Decapod auto-init in git repos ───────────────────────

  pi.on("session_start", async (_event, ctx) => {
    try {
      const gitCheck = await pi.exec("git", ["rev-parse", "--git-dir"], {
        timeout: 3000,
      });
      if (gitCheck.code !== 0) return;

      const cwd = ctx.cwd;
      const decapodDir = join(cwd, ".decapod");

      if (existsSync(decapodDir)) return;

      const init = await pi.exec("decapod", ["init", "--proof"], {
        timeout: 15000,
      });

      if (init.code === 0) {
        ensureGitignored(cwd, ".decapod/");
        ctx.ui.notify(
          "🏛️ Decapod auto-initialized (gitignored). Authorize `git add .decapod/` to commit.",
          "info",
        );
      }
    } catch {
      // decapod not installed — skip
    }
  });

  // ─── Rule 3: Block git add of governance artifacts ─────────────────

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "bash") return;

    const command =
      (event.input as Record<string, unknown>)?.command as string || "";

    const addsDecapod =
      /\bgit\s+add\b.*\.(decapod|\/decapod)/.test(command) ||
      /\bgit\s+add\b.*\bAGENTS\.md\b/.test(command);

    const forcedBroadAdd =
      /\bgit\s+add\s+(-[A-Za-z]*f|--force)/.test(command) &&
      /\bgit\s+add\b/.test(command);

    if (addsDecapod || forcedBroadAdd) {
      const allow = await ctx.ui.confirm(
        "🛡️ Decapod Git Guard",
        [
          "Governance: .decapod/ and AGENTS.md are gitignored by default.",
          "",
          `Command: ${command}`,
          "",
          "Allow this git add? (Only if you intend to commit decapod artifacts)",
        ].join("\n"),
      );

      if (!allow) {
        return {
          block: true,
          reason:
            "Blocked: .decapod/ and AGENTS.md are governance artifacts, gitignored by default.",
        };
      }
    }
  });

  // ─── Rule 4: Beads required before implementation ──────────────────
  //
  // On first `edit` or `write` (to code files), check if any bead is
  // in_progress. If not, warn and suggest creating one.
  //
  // Not a hard block — some edits are legitimate without beads
  // (config tweaks, docs). But the warning ensures visibility.
  //
  // Hard block on subagent workers: they MUST have a bead before
  // editing, since the orchestrator should have created one in the
  // dispatch prompt.

  const codeExtensions = new Set([
    ".ts", ".tsx", ".js", ".jsx", ".py", ".rs", ".go", ".el",
    ".rb", ".java", ".kt", ".swift", ".c", ".cpp", ".h", ".hpp",
    ".cs", ".sh", ".bash", ".zsh", ".lua", ".ex", ".exs",
  ]);

  function isCodeFile(filePath: string): boolean {
    const ext = filePath.slice(filePath.lastIndexOf("."));
    return codeExtensions.has(ext);
  }

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "edit" && event.toolName !== "write") return;

    const path =
      (event.input as Record<string, unknown>)?.path as string || "";

    if (!isCodeFile(path)) return; // Skip non-code files

    // Refresh if we haven't checked yet
    if (!beadCheckDone) {
      await refreshBeadsState();
    }

    if (beadClaimedThisSession) return; // Bead exists — proceed

    // No bead claimed. Check once more in case state changed outside session.
    await refreshBeadsState();

    if (beadClaimedThisSession) return; // Found one on refresh

    if (!isOrchestrator) {
      // Subagent workers: hard block — orchestrator should have created a bead
      return {
        block: true,
        reason: [
          "Blocked: no Bead in_progress. AGENTS.md requires a Bead before implementation.",
          "The orchestrator must create/claim a Bead before dispatching work:",
          '  br create "task description" && br update <id> --status in_progress',
        ].join("\n"),
      };
    }

    // Orchestrator: warn, don't block (might be a config tweak)
    ctx.ui.notify(
      "⚠️ No Bead in_progress. AGENTS.md: create/claim a Bead before implementation work.\n" +
      "  br create \"<task>\" && br update <id> --status in_progress",
      "warning",
    );
  });

  // ─── Rule 5: Unpushed commits at shutdown ──────────────────────────

  pi.on("session_shutdown", async (event, ctx) => {
    if (event.reason !== "quit") return;

    try {
      const status = await pi.exec("git", ["status", "--porcelain"], {
        timeout: 5000,
      });
      const log = await pi.exec(
        "git",
        ["log", "--oneline", "@{u}..HEAD"],
        { timeout: 5000 },
      );

      const dirty = status.stdout?.trim();
      const ahead = log.stdout?.trim();

      if (dirty || ahead) {
        const parts: string[] = [];
        if (dirty)
          parts.push(`${dirty.split("\n").length} uncommitted changes`);
        if (ahead)
          parts.push(`${ahead.split("\n").length} unpushed commits`);

        ctx.ui.notify(
          `⚠️ AGENTS.md violation: ${parts.join(" + ")}. Work is NOT complete until git push succeeds.`,
          "warning",
        );
      }
    } catch {
      // Not a git repo or no upstream — skip
    }
  });

  // ─── Rule 6: Context injection ─────────────────────────────────────
  //
  // Inject active beads and decapod status into system prompt so the
  // LLM has situational awareness without reading files.

  pi.on("before_agent_start", async (event, ctx) => {
    const sections: string[] = [];

    // Decapod status
    try {
      const gitCheck = await pi.exec("git", ["rev-parse", "--git-dir"], {
        timeout: 3000,
      });
      if (gitCheck.code !== 0) {
        sections.push(
          "## Governance: No Git Repo\n" +
          "Not inside a git repository. Decapod and Beads are unavailable. " +
          "Skip ALL Decapod/Beads initialization steps from AGENTS.md.",
        );
      }
    } catch {
      // skip
    }

    // Active beads
    if (beadCheckDone && activeBeadIds.length > 0) {
      sections.push(
        "## Governance: Active Beads\n" +
        `${activeBeadIds.length} bead(s) in_progress: ${activeBeadIds.join(", ")}.\n` +
        "Reference the relevant Bead ID in commit messages and subagent prompts.",
      );
    } else if (beadCheckDone && !beadClaimedThisSession) {
      sections.push(
        "## Governance: No Active Beads\n" +
        "No beads are in_progress. Before implementation work, create and claim a bead:\n" +
        "  br create \"<task>\" && br update <id> --status in_progress",
      );
    }

    if (sections.length > 0) {
      return {
        systemPrompt: event.systemPrompt + "\n\n" + sections.join("\n\n"),
      };
    }
  });
}

// ─── Helpers ──────────────────────────────────────────────────────────

function ensureGitignored(repoRoot: string, pattern: string): void {
  const gitignorePath = join(repoRoot, ".gitignore");

  try {
    if (existsSync(gitignorePath)) {
      const content = readFileSync(gitignorePath, "utf8");
      const lines = content.split("\n");
      if (lines.some((line) => line.trim() === pattern)) return;
      const needsNewline = content.length > 0 && !content.endsWith("\n");
      appendFileSync(
        gitignorePath,
        `${needsNewline ? "\n" : ""}# Decapod governance (auto-managed)\n${pattern}\n`,
      );
    } else {
      appendFileSync(
        gitignorePath,
        `# Decapod governance (auto-managed)\n${pattern}\n`,
      );
    }
  } catch {
    // Permission error — skip
  }
}
