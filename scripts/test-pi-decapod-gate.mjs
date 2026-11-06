// Drives the handlers of modules/M-02877/pi-decapod-gate.ts against a fake
// `decapod` on PATH. Run: node --test scripts/test-pi-decapod-gate.mjs
import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import gate from "../modules/M-02877/pi-decapod-gate.ts";

const tmp = realpathSync(mkdtempSync(join(tmpdir(), "decapod-gate-")));
const bin = join(tmp, "bin");
const emptyBin = join(tmp, "empty");
const log = join(tmp, "calls.log");
const project = join(tmp, "project");
const outside = join(tmp, "outside");
for (const dir of [bin, emptyBin, join(project, ".decapod"), join(project, "src"), outside]) {
  mkdirSync(dir, { recursive: true });
}
// BLOCKME blocks (exit 2), GARBAGE prints no JSON, anything else is allowed.
writeFileSync(
  join(bin, "decapod"),
  `#!/bin/sh
input=$(cat)
echo "$PWD $*" >> "${log}"
case "$input" in
  *BLOCKME*) echo '{"status":"block"}'; exit 2;;
  *GARBAGE*) echo 'not json'; exit 0;;
  *SLOWALLOW*) sleep 0.3;;
esac
echo '{"status":"allow"}'
`,
);
chmodSync(join(bin, "decapod"), 0o755);
const originalPath = process.env.PATH;
const useFakeDecapod = () => (process.env.PATH = `${bin}:${originalPath}`);
const calls = () => {
  try {
    return readFileSync(log, "utf8").trim().split("\n").filter(Boolean);
  } catch {
    return [];
  }
};

let clock = 0;
const user = (text) => ({ role: "user", content: text, timestamp: ++clock });
const custom = (text, from) => ({
  role: "custom",
  customType: "agent_message",
  content: text,
  details: { from },
  timestamp: ++clock,
});

function load(cwd = join(project, "src"), entries = []) {
  const handlers = {};
  const pi = {
    on: (name, fn) => (handlers[name] = fn),
    appendEntry: (customType, data) => entries.push({ type: "custom", customType, data }),
  };
  const ctx = { cwd, hasUI: false, sessionManager: { getBranch: () => entries } };
  gate(pi);
  handlers.session_start({}, ctx);
  return {
    entries,
    // Like pi: the handler is not awaited before the next event.
    receive: (message) => handlers.message_start({ message }, ctx),
    toolCall: () => handlers.tool_call({ toolName: "bash", input: {} }, ctx),
    input: (text, source) => handlers.input({ text, source }, ctx),
    beforeAgentStart: () => {
      const event = { systemPromptOptions: {} };
      handlers.before_agent_start(event, ctx);
      return event.systemPromptOptions.sections;
    },
    resume: () => handlers.session_start({}, ctx),
  };
}

test("an ordinary prompt runs tools and records an allow entry", async () => {
  useFakeDecapod();
  const s = load();
  s.receive(user("hello"));
  assert.equal(await s.toolCall(), undefined);
  assert.equal(s.entries.length, 1);
  assert.equal(s.entries[0].customType, "decapod-gate");
  assert.equal(s.entries[0].data.allowed, true);
  assert.equal(s.entries[0].data.status, "allow");
  assert.match(calls().at(-1), new RegExp(`^${project.replace(/[/.]/g, "\\$&")} eval --stdin --format json$`));
});

test("a blocked prompt blocks tools until an allowed human prompt", async () => {
  useFakeDecapod();
  const s = load();
  s.receive(user("BLOCKME"));
  const result = await s.toolCall();
  assert.equal(result.block, true);
  assert.match(result.reason, /the human prompt was not allowed \(status: block, exit 2\)/);
  assert.match(result.reason, /ask the human to review/);
  s.receive(user("BLOCKME again"));
  assert.equal((await s.toolCall()).block, true);
  s.receive(user("fine"));
  assert.equal(await s.toolCall(), undefined);
});

test("a custom message that arrives mid-turn is gated before the next tool call", async () => {
  useFakeDecapod();
  const s = load();
  s.receive(user("hello"));
  assert.equal(await s.toolCall(), undefined);
  // The message is received, but its gate has not finished when the tool call starts.
  s.receive(custom("BLOCKME", "Peer"));
  const result = await s.toolCall();
  assert.equal(result.block, true);
  assert.match(result.reason, /agent_message message from Peer was not allowed/);
  // An allowed custom message is not a human review.
  s.receive(custom("hi", "Peer"));
  assert.equal((await s.toolCall()).block, true);
  s.receive(user("reviewed"));
  assert.equal(await s.toolCall(), undefined);
});

test("a slow gate delays the tool call instead of racing it", async () => {
  useFakeDecapod();
  const s = load();
  s.receive(user("BLOCKME"));
  s.receive(user("SLOWALLOW"));
  // Both are queued: the later allowed human prompt clears the earlier block.
  assert.equal(await s.toolCall(), undefined);
});

test("a user message sent by an extension does not clear a block", async () => {
  useFakeDecapod();
  const s = load();
  s.receive(user("BLOCKME"));
  s.input("from an extension", "extension");
  s.receive(user("from an extension"));
  assert.equal((await s.toolCall()).block, true);
});

test("outside a Decapod project the extension never runs decapod", async () => {
  useFakeDecapod();
  const before = calls().length;
  const s = load(outside);
  s.receive(user("BLOCKME"));
  s.receive(custom("BLOCKME", "Peer"));
  assert.equal(await s.toolCall(), undefined);
  assert.equal(s.entries.length, 0);
  assert.equal(s.beforeAgentStart(), undefined);
  assert.equal(calls().length, before);
});

test("a missing decapod blocks tool calls with a clear reason", async () => {
  process.env.PATH = emptyBin;
  const s = load();
  s.receive(user("hello"));
  const result = await s.toolCall();
  assert.equal(result.block, true);
  assert.match(result.reason, /decapod did not run \(ENOENT\)/);
});

test("unparsable decapod output blocks", async () => {
  useFakeDecapod();
  const s = load();
  s.receive(user("GARBAGE"));
  assert.match((await s.toolCall()).reason, /unparsable decapod eval output/);
});

test("a resumed session keeps its block and does not gate old messages again", async () => {
  useFakeDecapod();
  const first = load();
  const old = user("BLOCKME");
  first.receive(old);
  assert.equal((await first.toolCall()).block, true);
  const resumed = load(join(project, "src"), first.entries);
  assert.equal((await resumed.toolCall()).block, true);
  const before = calls().length;
  resumed.receive(old);
  await resumed.toolCall();
  assert.equal(calls().length, before);
  assert.equal(resumed.entries.length, 1);
});

test("the system prompt says the gate runs automatically", () => {
  useFakeDecapod();
  assert.match(load().beforeAgentStart().decapod_gate, /runs automatically/);
});
