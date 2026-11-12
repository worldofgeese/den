// Drives the handlers of modules/M-02877/pi-decapod-gate.ts against a fake
// `decapod` on PATH. Run: node --test scripts/test-pi-decapod-gate.mjs
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { gate } from "../modules/M-02877/pi-decapod-gate.ts";

const tmp = realpathSync(mkdtempSync(join(tmpdir(), "decapod-gate-")));
const bin = join(tmp, "bin");
const emptyBin = join(tmp, "empty");
const log = join(tmp, "calls.log");
const project = join(tmp, "project");
const outside = join(tmp, "outside");
for (const dir of [bin, emptyBin, join(project, ".decapod"), join(project, "src"), outside]) {
  mkdirSync(dir, { recursive: true });
}
// BLOCKME blocks (exit 2), BLOCKZERO blocks with exit 0, ALLOWFAIL prints allow
// but exits 1, GARBAGE prints no JSON, anything else is allowed.
writeFileSync(
  join(bin, "decapod"),
  `#!/bin/sh
input=$(cat)
echo "$PWD $*" >> "${log}"
case "$input" in
  *BLOCKME*) echo '{"status":"block"}'; exit 2;;
  *BLOCKZERO*) echo '{"status":"block"}'; exit 0;;
  *ALLOWFAIL*) echo '{"status":"allow"}'; exit 1;;
  *GARBAGE*) echo 'not json'; exit 0;;
  *SLOWALLOW*) sleep 0.3;;
  *SLEEP30*) exec sleep 30;;
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

const extensionFile = join(tmp, "installed-extension.ts");
writeFileSync(extensionFile, "// stand-in for the installed extension\n");

function load(cwd = join(project, "src"), entries = [], options = {}) {
  const handlers = {};
  const tools = {};
  const pi = {
    on: (name, fn) => (handlers[name] = fn),
    registerTool: (tool) => (tools[tool.name] = tool),
    appendEntry: (customType, data) => entries.push({ type: "custom", customType, data }),
  };
  const ctx = { cwd, hasUI: false, sessionManager: { getBranch: () => entries } };
  gate(pi, { extensionFile, ...options });
  handlers.session_start({}, ctx);
  return {
    entries,
    tools,
    status: async () => JSON.parse((await tools.decapod_gate_status.execute()).content[0].text),
    results: () => entries.filter((entry) => entry.data.kind === "result").map((entry) => entry.data),
    // Like pi: the handler is not awaited before the next event.
    receive: (message) => handlers.message_start({ message }, ctx),
    toolCall: () => handlers.tool_call({ toolName: "bash", input: {} }, ctx),
    statusToolCall: () => handlers.tool_call({ toolName: "decapod_gate_status", input: {} }, ctx),
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
  assert.ok(s.entries.every((entry) => entry.customType === "decapod-gate"));
  assert.equal(s.results().length, 1);
  assert.equal(s.results()[0].allowed, true);
  assert.equal(s.results()[0].status, "allow");
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

test("a message that arrives while a tool call waits is gated before that tool call runs", async () => {
  useFakeDecapod();
  const s = load();
  s.receive(user("SLOWALLOW"));
  const pending = s.toolCall();
  s.receive(custom("BLOCKME", "Peer"));
  const result = await pending;
  assert.equal(result.block, true);
  assert.match(result.reason, /from Peer was not allowed/);
});

test("an extension message whose text pi expands still does not clear a block", async () => {
  useFakeDecapod();
  const s = load();
  s.receive(user("BLOCKME"));
  s.input("/skill:research", "extension");
  s.receive(user("the expanded skill body"));
  assert.equal((await s.toolCall()).block, true);
  // The extension input is used up: the next user message is a human prompt.
  s.input("fine", "interactive");
  s.receive(user("fine"));
  assert.equal(await s.toolCall(), undefined);
});

test("a failure while persisting a result keeps the gate working", async () => {
  useFakeDecapod();
  const entries = [];
  const handlers = {};
  const pi = {
    on: (name, fn) => (handlers[name] = fn),
    registerTool: () => {},
    appendEntry: () => {
      throw new Error("disk full");
    },
  };
  const ctx = { cwd: join(project, "src"), hasUI: false, sessionManager: { getBranch: () => entries } };
  gate(pi, { extensionFile });
  handlers.session_start({}, ctx);
  handlers.message_start({ message: user("BLOCKME") }, ctx);
  handlers.message_start({ message: custom("hi", "Peer") }, ctx);
  assert.equal((await handlers.tool_call({}, ctx)).block, true);
});

test("a gate that settles after a session switch does not touch the new session", async () => {
  useFakeDecapod();
  const entries = [];
  const s = load(join(project, "src"), entries);
  s.receive(user("BLOCKME"));
  assert.equal((await s.toolCall()).block, true);
  s.receive(user("SLOWALLOW"));
  s.resume();
  // The replayed block survives; the old allowed human result arrives late and is dropped.
  await new Promise((resolve) => setTimeout(resolve, 600));
  assert.equal((await s.toolCall()).block, true);
  assert.equal(entries.filter((entry) => entry.data.status === "allow").length, 0);
});

test("outside a Decapod project the extension never runs decapod", async () => {
  useFakeDecapod();
  const before = calls().length;
  const s = load(outside);
  s.receive(user("BLOCKME"));
  s.receive(custom("BLOCKME", "Peer"));
  assert.equal(await s.toolCall(), undefined);
  assert.deepEqual(s.entries.map((entry) => entry.data.kind), ["revision"]);
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
  assert.equal(resumed.results().length, 1);
});

test("the system prompt says the gate runs automatically", () => {
  useFakeDecapod();
  assert.match(load().beforeAgentStart().decapod_gate, /runs automatically/);
});

test("the status tool is read-only and reports the last evaluation", async () => {
  useFakeDecapod();
  const s = load();
  assert.equal(s.tools.decapod_gate_status.annotations.readOnlyHint, true);
  s.receive(user("hello"));
  await s.toolCall();
  const status = await s.status();
  assert.deepEqual(status.pending, { count: 0, startedAt: [] });
  assert.equal(status.lastEvaluation.allowed, true);
});

test("the revision entry is recorded at session start and matches the status tool", async () => {
  const s = load();
  const [entry] = s.entries;
  assert.equal(entry.customType, "decapod-gate");
  assert.equal(entry.data.kind, "revision");
  assert.equal(entry.data.extensionSha256, createHash("sha256").update(readFileSync(extensionFile)).digest("hex"));
  const { revision } = await s.status();
  assert.deepEqual(revision, { extensionSha256: entry.data.extensionSha256 });
  // An unreadable extension file is named, not hidden.
  const missing = load(join(project, "src"), [], { extensionFile: join(tmp, "no-such-file") });
  assert.match((await missing.status()).revision.extensionSha256, /^unreadable \(ENOENT\)$/);
});

test("a block with exit 0 still blocks", async () => {
  useFakeDecapod();
  const s = load();
  s.receive(user("BLOCKZERO"));
  assert.equal((await s.toolCall()).block, true);
});

test("a non-zero exit blocks even with allow output", async () => {
  useFakeDecapod();
  const s = load();
  s.receive(user("ALLOWFAIL"));
  const result = await s.toolCall();
  assert.equal(result.block, true);
  assert.match(result.reason, /allow, exit 1/);
});

test("allow, block and invalid output keep the contract", async () => {
  useFakeDecapod();
  const s = load();
  s.receive(user("fine"));
  assert.equal(await s.toolCall(), undefined);
  s.receive(user("BLOCKME"));
  assert.equal((await s.toolCall()).block, true);
  s.receive(user("GARBAGE"));
  assert.match((await s.toolCall()).reason, /unparsable decapod eval output/);
  assert.deepEqual(s.results().map((r) => r.allowed), [true, false, false]);
  assert.equal((await s.status()).pending.count, 0);
});

const tick = () => new Promise((resolve) => setImmediate(resolve));

test("an evaluation that has not spawned yet is already pending", async () => {
  useFakeDecapod();
  let release;
  const gateOpen = new Promise((resolve) => (release = resolve));
  const spawned = [];
  const delayedSpawn = async (command, args, options) => {
    await gateOpen;
    spawned.push(command);
    return spawn(command, args, options);
  };
  const s = load(join(project, "src"), [], { spawn: delayedSpawn });
  const beforeNormal = calls().length;
  s.receive(user("hello"));
  await tick();
  const status = await s.status();
  assert.equal(status.pending.count, 1);
  // The pending record is persisted before the spawn, not only counted.
  assert.deepEqual(s.entries.map((entry) => entry.data.kind), ["revision", "pending"]);
  assert.deepEqual(spawned, [], "nothing has spawned yet");
  assert.equal(calls().length, beforeNormal);
  release();
  assert.equal(await s.toolCall(), undefined);
  assert.deepEqual(spawned, ["decapod"]);
  assert.equal(calls().length, beforeNormal + 1);
  assert.equal((await s.status()).pending.count, 0);
  const kinds = s.entries.map((entry) => entry.data.kind);
  assert.deepEqual(kinds, ["revision", "pending", "result"]);
  const [pendingEntry, resultEntry] = s.entries.slice(1).map((entry) => entry.data);
  assert.equal(resultEntry.id, pendingEntry.id, "the result names the pending evaluation it settles");
});

test("the status tool call is not held back by the drain or blocked by the gate", async () => {
  useFakeDecapod();
  const s = load(join(project, "src"), [], { timeoutMs: 1500 });
  s.receive(user("SLEEP30"));
  await tick();
  // Through the live path: the tool_call handler returns at once and the tool sees the pending evaluation.
  const started = Date.now();
  assert.equal(await s.statusToolCall(), undefined);
  assert.ok(Date.now() - started < 500, "must not wait for the pending evaluation");
  assert.equal((await s.status()).pending.count, 1);
  // Other tools still wait for the drain, and the timed-out evaluation blocks them ...
  const blockedTool = await s.toolCall();
  assert.equal(blockedTool.block, true);
  // ... but the status tool still answers while the gate is blocked.
  assert.equal(await s.statusToolCall(), undefined);
  const status = await s.status();
  assert.equal(status.pending.count, 0);
  assert.equal(status.lastEvaluation.allowed, false);
});

test("the revision is fixed when the code loads, not re-read at each session start", async () => {
  const file = join(tmp, "replaced-extension.ts");
  writeFileSync(file, "old bytes");
  const s = load(join(project, "src"), [], { extensionFile: file });
  const before = (await s.status()).revision;
  writeFileSync(file, "new bytes after a deploy");
  s.resume();
  assert.deepEqual((await s.status()).revision, before);
  assert.equal(before.extensionSha256, createHash("sha256").update("old bytes").digest("hex"));
  assert.deepEqual(s.entries.filter((e) => e.data.kind === "revision").map((e) => e.data.extensionSha256), [
    before.extensionSha256,
    before.extensionSha256,
  ]);
});

test("a timed-out evaluation stays pending until its process has exited", async () => {
  useFakeDecapod();
  let realKill;
  // The child ignores the kill for 600 ms, as a slow-dying process would.
  const slowKill = (command, args, options) => {
    const child = spawn(command, args, options);
    realKill = child.kill.bind(child);
    child.kill = (signal) => void setTimeout(() => realKill(signal), 600);
    return child;
  };
  const s = load(join(project, "src"), [], { spawn: slowKill, timeoutMs: 300 });
  s.receive(user("SLEEP30"));
  await tick();
  await new Promise((resolve) => setTimeout(resolve, 450));
  // Past the timeout, before the process is gone.
  assert.equal((await s.status()).pending.count, 1);
  assert.equal(s.results().length, 0);
  const result = await s.toolCall();
  assert.equal(result.block, true);
  assert.match(result.reason, /timed out/);
  assert.equal((await s.status()).pending.count, 0);
});

test("a spawn error settles the evaluation and clears pending", async () => {
  const s = load(join(project, "src"), [], {
    spawn: async () => {
      throw Object.assign(new Error("no spawn"), { code: "EAGAIN" });
    },
  });
  s.receive(user("hello"));
  assert.match((await s.toolCall()).reason, /decapod did not start \(EAGAIN\)/);
  const status = await s.status();
  assert.equal(status.pending.count, 0);
  assert.equal(status.lastEvaluation.allowed, false);
});

after(() => {
  rmSync(tmp, { recursive: true, force: true });
});
