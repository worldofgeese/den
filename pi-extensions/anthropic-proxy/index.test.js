import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import register, { buildProviderConfig, loadModels } from "./index.js";

// Pi only resolves built-in API types on its default stream path, which is what
// subagents and background tasks use. A custom api string works on the session
// path and then throws an uncaught exception elsewhere, killing pi mid-session.
// This is the regression guard for that.
const BUILTIN_APIS = new Set([
  "anthropic-messages",
  "openai-completions",
  "openai-responses",
  "openai-codex-responses",
  "azure-openai-responses",
  "google-generative-ai",
  "google-vertex",
  "mistral-conversations",
  "bedrock-converse-stream",
  "pi-messages",
]);

test("provider api is a built-in pi API, never a custom string", () => {
  assert.ok(BUILTIN_APIS.has(buildProviderConfig([]).api));
});

test("gateway requires bearer auth, so authHeader is set", () => {
  assert.equal(buildProviderConfig([]).authHeader, true);
});

test("no custom streamSimple is registered", () => {
  assert.equal(buildProviderConfig([]).streamSimple, undefined);
});

test("api key is resolved at runtime by command, never inlined", () => {
  const { apiKey } = buildProviderConfig([]);
  assert.ok(apiKey.startsWith("!secretspec get "));
  assert.ok(apiKey.endsWith(" LEGO_GATEWAY_API_KEY"));
  assert.ok(!/vk_/.test(apiKey), "provider config must not contain a literal key");
});

test("base url targets the gateway's anthropic prefix", () => {
  assert.equal(
    buildProviderConfig([]).baseUrl,
    "https://api.genai.thelegogroup.com/anthropic"
  );
});

test("registers under the anthropic-proxy provider id", () => {
  const calls = [];
  register({ registerProvider: (id, config) => calls.push([id, config]) });
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], "anthropic-proxy");
});

function writeModels(models) {
  const path = join(mkdtempSync(join(tmpdir(), "gw-models-")), "models.json");
  writeFileSync(path, JSON.stringify(models));
  return path;
}

test("loadModels keeps well-formed entries", () => {
  const models = loadModels([
    writeModels([{ id: "m", name: "M", maxTokens: 64000, contextWindow: 200000 }]),
  ]);
  assert.equal(models.length, 1);
  assert.equal(models[0].id, "m");
});

test("loadModels drops entries with missing or non-positive limits", () => {
  const models = loadModels([
    writeModels([
      { id: "ok", name: "OK", maxTokens: 1, contextWindow: 1 },
      { name: "no id", maxTokens: 1, contextWindow: 1 },
      { id: "zero", name: "Zero", maxTokens: 0, contextWindow: 1 },
      { id: "missing", name: "Missing" },
    ]),
  ]);
  assert.deepEqual(
    models.map((m) => m.id),
    ["ok"]
  );
});

test("loadModels returns empty when models.json is absent", () => {
  assert.deepEqual(loadModels([join(tmpdir(), "definitely-not-here", "models.json")]), []);
});

test("loadModels falls back to a later candidate when the first is missing", () => {
  // pi's jiti loader does not reliably expose this module's own directory, so
  // the module-relative path can be wrong. Falling back is what keeps the
  // provider from registering with zero models.
  const real = writeModels([{ id: "m", name: "M", maxTokens: 1, contextWindow: 1 }]);
  const models = loadModels([join(tmpdir(), "nope", "models.json"), real]);
  assert.deepEqual(
    models.map((m) => m.id),
    ["m"]
  );
});

test("registering with no models is surfaced, not silent", () => {
  // A provider with zero models makes pi fall through to a different provider
  // entirely, which looks like an unrelated auth error. Fail loudly instead.
  const warnings = [];
  const warn = console.warn;
  console.warn = (...args) => warnings.push(args.join(" "));
  try {
    assert.deepEqual(loadModels([join(tmpdir(), "definitely-not-here", "models.json")]), []);
  } finally {
    console.warn = warn;
  }
  assert.ok(warnings.some((w) => w.includes("provider will have no models")));
});
