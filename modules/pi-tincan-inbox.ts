// Agent Tincan inbox peek for pi — the pi counterpart of `tincan hook claude-code`.
//
// `tincan hook` only speaks Claude Code's hook protocol, but the part worth
// reusing is the read: it looks at the relay once, takes nothing, and prints one
// line when teammate requests or replies are waiting. So pi runs it as a probe
// and delivers the line the way pi can — into the model's context at the start
// of each run, and into the UI once per change.
//
// Claiming stays with the agent: the notice tells it to call check_inbox.
//
// TINCAN_CONFIG names the pi identity on a host that also runs claude-code,
// codex-main, copilot-cli, cursor-cli and opencode-local; each agent has its own
// config under ~/.config/tincan/. Without it tincan falls back to client.json,
// which does not exist on a multi-agent host.
//
// No coordinator behaviour is invented here. The operator prompt in AGENTS.md
// says what to do with the notice; this file only makes sure pi hears it.

import { execFile } from "node:child_process";
import os from "node:os";
import path from "node:path";

const BIN = process.env.TINCAN_BIN ?? "tincan";
const CONFIG = process.env.TINCAN_CONFIG ?? path.join(os.homedir(), ".config/tincan/pi.json");

// before_agent_start blocks the run, so the probe has to lose quickly. The hook
// itself shares a 3 s deadline across its two reads; a timeout here means we go
// quiet rather than delay the turn.
const PEEK_TIMEOUT_MS = 1500;

function peek(): Promise<string | null> {
  return new Promise((resolve) => {
    execFile(
      BIN,
      ["hook", "claude-code"],
      { timeout: PEEK_TIMEOUT_MS, env: { ...process.env, TINCAN_CONFIG: CONFIG } },
      (error, stdout) => {
        // The hook exits 0 when it cannot read; a spawn failure or timeout is
        // not worth telling the user about, so both cases stay silent.
        if (error) return resolve(null);
        const line = stdout.trim();
        resolve(line.length > 0 ? line : null);
      },
    );
  });
}

export default function (pi) {
  // The last line the model was given, so a steady inbox is mentioned once
  // rather than before every turn.
  let announced = "";

  pi.on("session_start", async (_event, ctx) => {
    const line = await peek();
    if (!line) return;
    announced = line;
    ctx.ui.notify(line, "info");
  });

  pi.on("before_agent_start", async (event) => {
    // Only user-initiated runs: answering our own injected message would loop.
    if (event.messageType !== "user") return;

    const line = await peek();
    if (!line) {
      announced = ""; // inbox drained: a later arrival is news again
      return;
    }
    if (line === announced) return;

    announced = line;
    return {
      message: {
        customType: "tincan-inbox",
        content: line,
        display: true,
      },
    };
  });
}
