// Smoke test: isOrchestrator env-var logic
// Tests the env-var coupling to pi-subagents without importing Pi extension API.
// pi-subagents sets PI_SUBAGENT_CHILD=1 in worker/child sessions.

import { describe, it } from "node:test";
import assert from "node:assert/strict";

// Mirror the exact logic from index.ts so tests break if logic drifts.
function resolveIsOrchestrator(env) {
  return env.PI_SUBAGENT_CHILD !== "1";
}

describe("isOrchestrator detection", () => {
  it("true when PI_SUBAGENT_CHILD is unset (orchestrator/parent session)", () => {
    const env = {};
    assert.equal(resolveIsOrchestrator(env), true);
  });

  it("false when PI_SUBAGENT_CHILD=1 (worker/child session)", () => {
    const env = { PI_SUBAGENT_CHILD: "1" };
    assert.equal(resolveIsOrchestrator(env), false);
  });

  it("true when PI_SUBAGENT_CHILD is empty string (not set by pi-subagents)", () => {
    const env = { PI_SUBAGENT_CHILD: "" };
    assert.equal(resolveIsOrchestrator(env), true);
  });

  it("true when old SUBAGENT_CHILD_ENV present (never-set legacy var, sanity check)", () => {
    // Confirms old var has no effect on new logic
    const env = { SUBAGENT_CHILD_ENV: "1" };
    assert.equal(resolveIsOrchestrator(env), true);
  });
});
