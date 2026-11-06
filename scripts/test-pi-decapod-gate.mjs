// Drives the handlers of modules/M-02877/pi-decapod-gate.ts against a fake
// `decapod` on PATH. Run: node --test scripts/test-pi-decapod-gate.mjs
import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
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
// The PAUSE route. The marker and runner paths go in as factory arguments, as in
// the installed extension, where they are baked in at build time.
const pauseMarker = join(tmp, "decapod-pause");
const runnerLog = join(tmp, "runner.log");
const runnerStub = (name, body) => {
  const path = join(tmp, name);
  writeFileSync(path, `#!/bin/sh\ninput=$(cat)\necho "$PWD path=$(/usr/bin/env | /usr/bin/grep -c ^PATH=) $input" >> "${runnerLog}"\n${body}\n`);
  chmodSync(path, 0o755);
  return path;
};
const runners = {
  allow: runnerStub("runner-allow", `echo '{"status":"allow"}'`),
  block: runnerStub("runner-block", `echo '{"status":"block"}'; exit 2`),
  blockExitZero: runnerStub("runner-block-zero", `echo '{"status":"block"}'`),
  fail: runnerStub("runner-fail", `echo '{"status":"allow"}'; exit 1`),
  garbage: runnerStub("runner-garbage", `echo 'not json'`),
  missing: join(tmp, "no-such-runner"),
};
const runnerCalls = () => {
  try {
    return readFileSync(runnerLog, "utf8").trim().split("\n").filter(Boolean);
  } catch {
    return [];
  }
};
const pause = () => writeFileSync(pauseMarker, "");
const resume = () => rmSync(pauseMarker, { force: true });
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

function load(cwd = join(project, "src"), entries = [], pauseRunner = runners.allow) {
  const handlers = {};
  const pi = {
    on: (name, fn) => (handlers[name] = fn),
    appendEntry: (customType, data) => entries.push({ type: "custom", customType, data }),
  };
  const ctx = { cwd, hasUI: false, sessionManager: { getBranch: () => entries } };
  gate(pi, { pauseMarker, pauseRunner });
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
    appendEntry: () => {
      throw new Error("disk full");
    },
  };
  const ctx = { cwd: join(project, "src"), hasUI: false, sessionManager: { getBranch: () => entries } };
  gate(pi, { pauseMarker, pauseRunner: runners.allow });
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

// Decapod cutover PAUSE: the marker exists, so only the pinned G5 runner runs.
// The fake decapod is first on PATH and logs every call, so a fallback shows.
function paused(runner, fn) {
  return async () => {
    useFakeDecapod();
    pause();
    const before = calls().length;
    try {
      await fn(load(join(project, "src"), [], runner));
    } finally {
      resume();
    }
    assert.equal(calls().length, before, "the decapod on PATH must never run during PAUSE");
  };
}

test("PAUSE: the runner prints allow, tools run, and the runner gets the prompt in a neutral directory with no PATH", paused(runners.allow, async (s) => {
  const before = runnerCalls().length;
  s.receive(user("hello PAUSE"));
  assert.equal(await s.toolCall(), undefined);
  assert.equal(s.entries[0].data.allowed, true);
  const [call] = runnerCalls().slice(before);
  assert.match(call, /^\/ path=0 hello PAUSE$/);
}));

test("PAUSE: the runner prints block, tools are blocked", paused(runners.block, async (s) => {
  s.receive(user("hello"));
  const result = await s.toolCall();
  assert.equal(result.block, true);
  assert.match(result.reason, /status: block, exit 2/);
}));

test("PAUSE: block with exit 0 still blocks", paused(runners.blockExitZero, async (s) => {
  s.receive(user("hello"));
  assert.equal((await s.toolCall()).block, true);
}));

test("PAUSE: a missing runner blocks and does not fall back to decapod", paused(runners.missing, async (s) => {
  s.receive(user("hello"));
  const result = await s.toolCall();
  assert.equal(result.block, true);
  assert.match(result.reason, /did not run \(ENOENT\)/);
}));

test("PAUSE: a non-zero exit blocks even with allow output", paused(runners.fail, async (s) => {
  s.receive(user("hello"));
  const result = await s.toolCall();
  assert.equal(result.block, true);
  assert.match(result.reason, /allow, exit 1/);
}));

test("PAUSE: invalid JSON blocks", paused(runners.garbage, async (s) => {
  s.receive(user("hello"));
  assert.match((await s.toolCall()).reason, /unparsable decapod eval output/);
}));

test("PAUSE: the marker is checked on every evaluation, so RESUME restores the normal route", async () => {
  useFakeDecapod();
  const s = load(join(project, "src"), [], runners.block);
  const start = { normal: calls().length, runner: runnerCalls().length };
  s.receive(user("before"));
  assert.equal(await s.toolCall(), undefined);
  assert.equal(calls().length, start.normal + 1);
  pause();
  s.receive(user("during"));
  assert.equal((await s.toolCall()).block, true);
  assert.equal(runnerCalls().length, start.runner + 1);
  assert.equal(calls().length, start.normal + 1);
  resume();
  s.receive(user("after"));
  assert.equal(await s.toolCall(), undefined);
  assert.equal(calls().length, start.normal + 2);
  assert.equal(runnerCalls().length, start.runner + 1);
});

test("PAUSE: a marker that cannot be checked counts as paused", async () => {
  useFakeDecapod();
  // ENOTDIR, not ENOENT: a file stands where the marker's directory should be.
  const handlers = {};
  const entries = [];
  const pi = { on: (name, fn) => (handlers[name] = fn), appendEntry: (t, data) => entries.push(data) };
  const ctx = { cwd: join(project, "src"), hasUI: false, sessionManager: { getBranch: () => [] } };
  gate(pi, { pauseMarker: join(runners.allow, "marker"), pauseRunner: runners.block });
  handlers.session_start({}, ctx);
  const before = calls().length;
  handlers.message_start({ message: user("hello") }, ctx);
  assert.equal((await handlers.tool_call({}, ctx)).block, true);
  assert.equal(calls().length, before);
});
