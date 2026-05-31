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
 *   4. Beads required before code edits (reads shared state from beads-rust ext)
 *   5. Unpushed commits warning at session shutdown
 *   6. No-decapod/no-git system prompt injection
 *
 * Beads state is owned by the beads-rust extension (pi-extensions/beads-rust/).
 * This extension reads it from globalThis.__beadsRustState to avoid duplicate
 * br CLI calls and broken JSON parsing.
 */

// ─── Shared state interface (published by beads-rust extension) ──────

interface BeadsSharedState {
  available: boolean;
  initialized: boolean;
  activeBeadIds: string[];
  checkedAt: number;
}

const BEADS_GLOBAL_KEY = "__beadsRustState";

function getBeadsState(): BeadsSharedState | null {
  const state = (globalThis as Record<string, unknown>)[BEADS_GLOBAL_KEY];
  if (state && typeof state === "object" && "available" in state) {
    return state as BeadsSharedState;
  }
  return null;
}

// ─── Extension ───────────────────────────────────────────────────────

export default function (pi: ExtensionAPI) {
  // PI_SUBAGENT_CHILD=1 is set by pi-subagents for all worker/child sessions.
  // See: node_modules/pi-subagents/src/runs/shared/pi-args.ts lines 14, 157.
  // When unset (parent/orchestrator session), isOrchestrator=true.
  const isOrchestrator = process.env.PI_SUBAGENT_CHILD !== "1";

  // ─── Rule 1: Orchestrator edit gate ────────────────────────────────

  if (isOrchestrator) {
    pi.on("tool_call", async (event, ctx) => {
      if (event.toolName !== "edit" && event.toolName !== "write") return;

      const path =
        (event.input as Record<string, unknown>)?.path as string || "unknown";

      ctx.ui.notify(
        `🛡️ Orchestrator Edit Guard — blocked ${event.toolName} to: ${path}\n` +
        "AGENTS.md: orchestrator must not do implementation work directly.\n" +
        "Delegate to a worker subagent instead.",
        "warning",
      );

      return {
        block: true,
        reason: [
          "Blocked by governance extension (hard deny, no override).",
          `Attempted: ${event.toolName} → ${path}`,
          "Orchestrator must not do implementation work directly.",
          "Dispatch to a worker subagent:",
          '  subagent({ agent: "worker", task: "..." })',
        ].join("\n"),
      };
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

      // Only auto-init when explicitly opted in via env var
      if (process.env.DECAPOD_AUTO_INIT !== "1") return;

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

  // ─── Rule 4: Beads required before code edits ──────────────────────
  //
  // Reads shared state from beads-rust extension via globalThis.
  // Workers: hard block. Orchestrator: warning only.

  const codeExtensions = new Set([
    ".ts", ".tsx", ".js", ".jsx", ".py", ".rs", ".go", ".el",
    ".rb", ".java", ".kt", ".swift", ".c", ".cpp", ".h", ".hpp",
    ".cs", ".sh", ".bash", ".zsh", ".lua", ".ex", ".exs", ".nix",
  ]);

  function isCodeFile(filePath: string): boolean {
    const dot = filePath.lastIndexOf(".");
    if (dot < 0) return false;
    return codeExtensions.has(filePath.slice(dot));
  }

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "edit" && event.toolName !== "write") return;

    const path =
      (event.input as Record<string, unknown>)?.path as string || "";

    if (!isCodeFile(path)) return;

    const beads = getBeadsState();

    // State never published by beads-rust extension → fail-closed
    if (!beads) {
      if (!isOrchestrator) {
        return {
          block: true,
          reason: "Beads state unavailable — cannot verify active bead. Ensure beads-rust extension is loaded.",
        };
      }
      ctx.ui.notify(
        "⚠️ Beads state unavailable — cannot verify active bead. Ensure beads-rust extension is loaded.",
        "warning",
      );
      return;
    }

    // br CLI not installed or repo not initialized → skip enforcement
    if (!beads.available || !beads.initialized) return;

    // Beads active and claimed → allow
    if (beads.activeBeadIds.length > 0) return;

    if (!isOrchestrator) {
      // Workers: hard block
      return {
        block: true,
        reason: [
          "Blocked: no Bead in_progress. AGENTS.md requires a Bead before implementation.",
          "The orchestrator must create/claim a Bead before dispatching work:",
          '  RUST_LOG=error br create "task" --json && br update <id> --claim --json',
        ].join("\n"),
      };
    }

    // Orchestrator: warn
    ctx.ui.notify(
      "⚠️ No Bead in_progress. Create/claim before implementation:\n" +
      '  RUST_LOG=error br create "<task>" --json && br update <id> --claim --json',
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

  // ─── Rule 6: System prompt context ─────────────────────────────────
  //
  // Inject decapod/git status. Beads context is handled by beads-rust
  // extension — governance only adds enforcement notes.

  pi.on("before_agent_start", async (event, ctx) => {
    try {
      const gitCheck = await pi.exec("git", ["rev-parse", "--git-dir"], {
        timeout: 3000,
      });
      if (gitCheck.code !== 0) {
        return {
          systemPrompt:
            event.systemPrompt +
            "\n\n## Governance: No Git Repo\n" +
            "Not inside a git repository. Decapod and Beads are unavailable. " +
            "Skip ALL Decapod/Beads initialization steps from AGENTS.md.",
        };
      }
    } catch {
      // skip
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
