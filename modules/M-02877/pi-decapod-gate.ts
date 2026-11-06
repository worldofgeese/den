// Managed by den (modules/M-02877/agent-integrations.nix). Edits are overwritten.
//
// Runs the Decapod prompt safety gate (AGENTS.md, "Mandatory Prompt Safety
// Gate") for the agent, so it no longer depends on the agent remembering to.
// On 2026-11-05 the manual gate ran about 70 times in one session, was skipped
// three times, and twice ran in parallel with other tool calls, so actions ran
// before a `block` was seen.
//
// Only active when the session cwd is inside a project that has `.decapod/`.
// Every incoming message (human prompt or injected custom message, also one
// steered into a running turn) goes through `decapod eval --stdin --format
// json` in the project root. A message is allowed only when the command exits
// 0 and reports status "allow"; anything else fails closed. Tool calls wait for
// all received messages to finish gating, and are blocked while a message since
// the last clear was not allowed. An allowed human prompt clears the block: it
// is the human review that the contract asks for.
//
// Plain JavaScript on purpose, so node can run the test without a build step.
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";

const ENTRY_TYPE = "decapod-gate";
const GATE_TIMEOUT_MS = 20_000;
const PROMPT_LINE =
  "The Decapod prompt safety gate runs automatically: an extension evaluates every incoming message with `decapod eval` before any tool call. Do not run the manual gate from AGENTS.md. If a tool call is blocked by the gate, stop and ask the human to review.";

// Nearest ancestor directory that holds `.decapod/`, or undefined.
function decapodRoot(cwd) {
  for (let dir = cwd; ; dir = dirname(dir)) {
    if (existsSync(join(dir, ".decapod"))) return dir;
    if (dirname(dir) === dir) return undefined;
  }
}

function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((part) => part?.type === "text")
    .map((part) => part.text)
    .join("\n");
}

// Resolves to { allowed, status }; never rejects.
function evaluate(root, text) {
  return new Promise((resolve) => {
    let out = "";
    let settled = false;
    let timer;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(result);
    };
    let child;
    try {
      child = spawn("decapod", ["eval", "--stdin", "--format", "json"], {
        cwd: root,
        stdio: ["pipe", "pipe", "ignore"],
      });
    } catch (error) {
      return finish({ allowed: false, status: `decapod did not start (${error.code ?? error.message})` });
    }
    timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish({ allowed: false, status: `decapod eval timed out after ${GATE_TIMEOUT_MS / 1000}s` });
    }, GATE_TIMEOUT_MS);
    child.on("error", (error) =>
      finish({ allowed: false, status: `decapod did not run (${error.code ?? error.message})` }),
    );
    child.stdin.on("error", () => {});
    child.stdout.on("data", (chunk) => (out += chunk));
    child.on("close", (code) => {
      let status;
      try {
        status = JSON.parse(out).status;
      } catch {
        return finish({ allowed: false, status: `unparsable decapod eval output (exit ${code})` });
      }
      if (code !== 0) return finish({ allowed: false, status: `${status ?? "no status"}, exit ${code}` });
      finish({ allowed: status === "allow", status: String(status) });
    });
    child.stdin.end(text);
  });
}

function describe(message, extensionSent) {
  if (message.role === "user") {
    return extensionSent
      ? { human: false, sender: "a user message from an extension" }
      : { human: true, sender: "the human prompt" };
  }
  const from = message.details?.from;
  return {
    human: false,
    sender: `${message.customType ?? "custom"} message${typeof from === "string" ? ` from ${from}` : ""}`,
  };
}

export default function (pi) {
  // The latest message that was not allowed since the last clear.
  let blocked;
  // Keys of messages that already have a persisted result.
  const gated = new Set();
  // Texts that extensions sent as user messages: not human prompts.
  const extensionTexts = new Set();
  // Messages gate one at a time in arrival order, so a later human prompt
  // clears only the blocks that came before it.
  let queue = Promise.resolve();

  const record = (data) => {
    gated.add(data.key);
    if (data.allowed) {
      if (data.human) blocked = undefined;
    } else {
      blocked = { sender: data.sender, status: data.status };
    }
  };

  pi.on("session_start", (_event, ctx) => {
    blocked = undefined;
    gated.clear();
    queue = Promise.resolve();
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type === "custom" && entry.customType === ENTRY_TYPE && entry.data?.key) record(entry.data);
    }
  });

  pi.on("input", (event) => {
    if (event.source === "extension") extensionTexts.add(event.text);
    return { action: "continue" };
  });

  pi.on("before_agent_start", (event, ctx) => {
    if (!decapodRoot(ctx.cwd)) return;
    (event.systemPromptOptions.sections ??= {}).decapod_gate = PROMPT_LINE;
  });

  pi.on("message_start", (event, ctx) => {
    const message = event.message;
    if (message?.role !== "user" && message?.role !== "custom") return;
    const root = decapodRoot(ctx.cwd);
    if (!root) return;
    const text = textOf(message.content);
    const key = createHash("sha256").update(`${message.role}\0${message.timestamp}\0${text}`).digest("hex");
    const { human, sender } = describe(message, message.role === "user" && extensionTexts.delete(text));
    queue = queue.then(async () => {
      if (gated.has(key)) return;
      const { allowed, status } = await evaluate(root, text);
      const data = { key, sender, human, allowed, status };
      record(data);
      pi.appendEntry(ENTRY_TYPE, data);
      if (!allowed && ctx.hasUI) ctx.ui.notify(`Decapod prompt gate: ${sender} not allowed (${status})`, "error");
    });
  });

  pi.on("tool_call", async (_event, ctx) => {
    if (!decapodRoot(ctx.cwd)) return;
    await queue;
    if (!blocked) return;
    const reason = `Decapod prompt gate: ${blocked.sender} was not allowed (status: ${blocked.status}). Stop and ask the human to review it. A later allowed human prompt clears this block.`;
    if (ctx.hasUI) ctx.ui.notify(reason, "error");
    return { block: true, reason };
  });
}
