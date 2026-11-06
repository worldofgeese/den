// Drives the handlers of modules/M-02877/pi-decapod-gate.ts against a fake
// `decapod` on PATH. Run: node --test scripts/test-pi-decapod-gate.mjs
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { chmodSync, closeSync, lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
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
  *SLEEP30*) exec sleep 30;;
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
// Creates the marker exclusively (O_EXCL), refuses to run over an existing one,
// and removes only a marker that this run created.
let createdMarker = false;
const pause = () => {
  closeSync(openSync(pauseMarker, "wx"));
  createdMarker = true;
};
const resume = () => {
  if (!createdMarker) return;
  rmSync(pauseMarker, { force: true });
  createdMarker = false;
};
const originalPath = process.env.PATH;
{
  let existing = true;
  try {
    lstatSync(pauseMarker);
  } catch {
    existing = false;
  }
  assert.equal(existing, false, `refusing to run: ${pauseMarker} already exists`);
}
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

function load(cwd = join(project, "src"), entries = [], pauseRunner = runners.allow, options = {}) {
  const handlers = {};
  const tools = {};
  const pi = {
    on: (name, fn) => (handlers[name] = fn),
    registerTool: (tool) => (tools[tool.name] = tool),
    appendEntry: (customType, data) => entries.push({ type: "custom", customType, data }),
  };
  const ctx = { cwd, hasUI: false, sessionManager: { getBranch: () => entries } };
  gate(pi, { pauseMarker, pauseRunner, extensionFile, ...options });
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
  assert.equal(s.results()[0].route, "normal");
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
  gate(pi, { pauseMarker, pauseRunner: runners.allow, extensionFile });
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
  assert.equal(s.results()[0].allowed, true);
  assert.equal(s.results()[0].route, "g5");
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

// A marker that exists but cannot be inspected blocks. It selects neither route.
function blockedByMarkerError(code, makeMarker) {
  return async () => {
    useFakeDecapod();
    const marker = makeMarker();
    const entries = [];
    const s = load(join(project, "src"), entries, runners.allow, { pauseMarker: marker });
    const beforeNormal = calls().length;
    const beforeRunner = runnerCalls().length;
    s.receive(user("hello"));
    const result = await s.toolCall();
    assert.equal(result.block, true);
    assert.match(result.reason, new RegExp(`PAUSE marker cannot be inspected \\(${code}\\)`));
    assert.equal(calls().length, beforeNormal, "PATH must not be selected");
    assert.equal(runnerCalls().length, beforeRunner, "G5 must not be selected");
    assert.equal(s.results()[0].route, "blocked");
    const status = await s.status();
    assert.deepEqual(status.marker, { state: "error", error: code });
    assert.equal(status.pendingNormal.count, 0);
  };
}

test(
  "a marker in a directory with mode 000 blocks: neither PATH nor G5",
  { skip: process.getuid?.() === 0 && "root ignores directory modes" },
  async () => {
    const dir = join(tmp, "no-access");
    mkdirSync(dir, { recursive: true });
    chmodSync(dir, 0o000);
    try {
      await blockedByMarkerError("EACCES", () => join(dir, "marker"))();
    } finally {
      chmodSync(dir, 0o755);
    }
  },
);

test("a marker path with a symlink loop blocks (ELOOP)", blockedByMarkerError("ELOOP", () => {
  symlinkSync(join(tmp, "loop"), join(tmp, "loop"));
  return join(tmp, "loop", "marker");
}));

test("a marker path through a file blocks (ENOTDIR)", blockedByMarkerError("ENOTDIR", () => join(runners.allow, "marker")));

test("the status tool is read-only and reports no marker without one", async () => {
  useFakeDecapod();
  const s = load();
  assert.equal(s.tools.decapod_gate_status.annotations.readOnlyHint, true);
  s.receive(user("hello"));
  await s.toolCall();
  const status = await s.status();
  assert.deepEqual(status.marker, { state: "absent" });
  assert.deepEqual(status.pendingNormal, { count: 0, startedAt: [] });
  assert.equal(status.lastEvaluation.route, "normal");
  assert.equal(status.lastEvaluation.allowed, true);
  assert.equal(status.g5SettledSinceMarkerSeen, false);
});

test("the revision entry is recorded at session start and matches the status tool", async () => {
  const s = load();
  const [entry] = s.entries;
  assert.equal(entry.customType, "decapod-gate");
  assert.equal(entry.data.kind, "revision");
  assert.equal(entry.data.runner, runners.allow);
  assert.equal(entry.data.extensionSha256, createHash("sha256").update(readFileSync(extensionFile)).digest("hex"));
  const { revision } = await s.status();
  assert.deepEqual(revision, { runner: entry.data.runner, extensionSha256: entry.data.extensionSha256 });
  // An unreadable extension file is named, not hidden.
  const missing = load(join(project, "src"), [], runners.allow, { extensionFile: join(tmp, "no-such-file") });
  assert.match((await missing.status()).revision.extensionSha256, /^unreadable \(ENOENT\)$/);
});

test("a normal-route allow, block, non-zero exit and invalid output keep the contract without a marker", async () => {
  useFakeDecapod();
  const s = load();
  s.receive(user("fine"));
  assert.equal(await s.toolCall(), undefined);
  s.receive(user("BLOCKME"));
  assert.equal((await s.toolCall()).block, true);
  s.receive(user("GARBAGE"));
  assert.match((await s.toolCall()).reason, /unparsable decapod eval output/);
  assert.deepEqual(s.results().map((r) => [r.route, r.allowed]), [["normal", true], ["normal", false], ["normal", false]]);
  assert.equal((await s.status()).pendingNormal.count, 0);
});

const tick = () => new Promise((resolve) => setImmediate(resolve));

test("transition: a delayed normal-route evaluation stays pending after the marker is armed, then G5 takes over", async () => {
  useFakeDecapod();
  const s = load(join(project, "src"), [], runners.allow, { timeoutMs: 1500 });
  const beforeRunner = runnerCalls().length;
  s.receive(user("SLEEP30"));
  await tick();
  const armedAt = Date.now();
  pause();
  s.receive(user("after the marker"));
  const during = await s.status();
  assert.equal(during.marker.state, "present");
  assert.equal(during.pendingNormal.count, 1);
  assert.equal(during.pendingNormal.startedAt.length, 1);
  assert.ok(Date.parse(during.pendingNormal.startedAt[0]) <= armedAt);
  assert.equal(during.g5SettledSinceMarkerSeen, false);
  assert.equal(runnerCalls().length, beforeRunner, "the next evaluation waits behind the pending one");
  // The delayed evaluation blocks on timeout; only then does the next one run, on G5.
  const result = await s.toolCall();
  assert.equal(result, undefined);
  const results = s.results();
  assert.deepEqual(results.map((r) => [r.route, r.allowed]), [["normal", false], ["g5", true]]);
  assert.match(results[0].status, /timed out/);
  const after = await s.status();
  assert.equal(after.pendingNormal.count, 0);
  assert.equal(after.lastEvaluation.route, "g5");
  assert.equal(after.g5SettledSinceMarkerSeen, true);
  assert.equal(runnerCalls().length, beforeRunner + 1);
  // Pending and settled records are persisted with their routes.
  const kinds = s.entries.map((entry) => `${entry.data.kind}:${entry.data.route ?? ""}`);
  assert.deepEqual(kinds, ["revision:", "pending:normal", "result:normal", "pending:g5", "result:g5"]);
  resume();
  const resumed = await s.status();
  assert.equal(resumed.marker.state, "absent");
  assert.equal(resumed.g5SettledSinceMarkerSeen, false);
});

test("an evaluation that chose its route before the marker but has not spawned yet is pending", async () => {
  useFakeDecapod();
  let release;
  const gateOpen = new Promise((resolve) => (release = resolve));
  const spawned = [];
  const delayedSpawn = async (command, args, options) => {
    await gateOpen;
    spawned.push(command);
    return spawn(command, args, options);
  };
  const s = load(join(project, "src"), [], runners.allow, { spawn: delayedSpawn });
  const beforeNormal = calls().length;
  s.receive(user("hello"));
  await tick();
  pause();
  const status = await s.status();
  assert.equal(status.marker.state, "present");
  assert.equal(status.pendingNormal.count, 1);
  assert.deepEqual(spawned, [], "nothing has spawned yet");
  assert.equal(calls().length, beforeNormal);
  release();
  assert.equal(await s.toolCall(), undefined);
  assert.deepEqual(spawned, ["decapod"]);
  assert.equal(calls().length, beforeNormal + 1);
  assert.equal((await s.status()).pendingNormal.count, 0);
  resume();
});

test("the status tool call is not held back by the drain or blocked by the gate", async () => {
  useFakeDecapod();
  const s = load(join(project, "src"), [], runners.allow, { timeoutMs: 1500 });
  s.receive(user("SLEEP30"));
  await tick();
  // Through the live path: the tool_call handler returns at once and the tool sees the pending evaluation.
  const started = Date.now();
  assert.equal(await s.statusToolCall(), undefined);
  assert.ok(Date.now() - started < 500, "must not wait for the pending evaluation");
  assert.equal((await s.status()).pendingNormal.count, 1);
  // Other tools still wait for the drain, and the timed-out evaluation blocks them ...
  const blockedTool = await s.toolCall();
  assert.equal(blockedTool.block, true);
  // ... but the status tool still answers while the gate is blocked.
  assert.equal(await s.statusToolCall(), undefined);
  const status = await s.status();
  assert.equal(status.pendingNormal.count, 0);
  assert.equal(status.lastEvaluation.allowed, false);
});

test("the revision is fixed when the code loads, not re-read at each session start", async () => {
  const file = join(tmp, "replaced-extension.ts");
  writeFileSync(file, "old bytes");
  const s = load(join(project, "src"), [], runners.allow, { extensionFile: file });
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
  const s = load(join(project, "src"), [], runners.allow, { spawn: slowKill, timeoutMs: 300 });
  s.receive(user("SLEEP30"));
  await tick();
  await new Promise((resolve) => setTimeout(resolve, 450));
  // Past the timeout, before the process is gone.
  assert.equal((await s.status()).pendingNormal.count, 1);
  assert.equal(s.results().length, 0);
  const result = await s.toolCall();
  assert.equal(result.block, true);
  assert.match(result.reason, /timed out/);
  assert.equal((await s.status()).pendingNormal.count, 0);
});

test("a spawn error settles the evaluation and clears pending", async () => {
  const s = load(join(project, "src"), [], runners.allow, {
    spawn: async () => {
      throw Object.assign(new Error("no spawn"), { code: "EAGAIN" });
    },
  });
  s.receive(user("hello"));
  assert.match((await s.toolCall()).reason, /decapod did not start \(EAGAIN\)/);
  const status = await s.status();
  assert.equal(status.pendingNormal.count, 0);
  assert.equal(status.lastEvaluation.allowed, false);
});

after(() => {
  resume();
  rmSync(tmp, { recursive: true, force: true });
});
