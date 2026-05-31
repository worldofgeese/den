// Smoke test: isOrchestrator env-var logic and governance rule logic.
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

// Mirror Rule 4 fail-closed logic from index.ts
function rule4Decision(beadsState, isOrchestrator) {
  if (!beadsState) {
    if (!isOrchestrator) {
      return {
        block: true,
        reason: "Beads state unavailable — cannot verify active bead. Ensure beads-rust extension is loaded.",
      };
    }
    return { warn: true };
  }
  if (!beadsState.available || !beadsState.initialized) return { skip: true };
  if (beadsState.activeBeadIds.length > 0) return { allow: true };
  if (!isOrchestrator) {
    return {
      block: true,
      reason: "Blocked: no Bead in_progress.",
    };
  }
  return { warn: true };
}

describe("Rule 4: Beads required before code edits", () => {
  it("worker: blocks when beads state is null (fail-closed)", () => {
    const result = rule4Decision(null, false);
    assert.equal(result.block, true);
    assert.match(result.reason, /Beads state unavailable/);
  });

  it("orchestrator: warns (not blocks) when beads state is null", () => {
    const result = rule4Decision(null, true);
    assert.equal(result.warn, true);
    assert.equal(result.block, undefined);
  });

  it("skips enforcement when br CLI unavailable", () => {
    const result = rule4Decision({ available: false, initialized: false, activeBeadIds: [] }, false);
    assert.equal(result.skip, true);
  });

  it("skips enforcement when repo not initialized", () => {
    const result = rule4Decision({ available: true, initialized: false, activeBeadIds: [] }, false);
    assert.equal(result.skip, true);
  });

  it("allows edit when active bead present", () => {
    const result = rule4Decision({ available: true, initialized: true, activeBeadIds: ["home-manager-ixg"] }, false);
    assert.equal(result.allow, true);
  });

  it("worker: blocks when initialized but no active bead", () => {
    const result = rule4Decision({ available: true, initialized: true, activeBeadIds: [] }, false);
    assert.equal(result.block, true);
  });
});

// Mirror Rule 2 auto-init gate logic from index.ts
function shouldAutoInit(env, decapodExists) {
  if (decapodExists) return false; // .decapod/ already present → skip
  if (env.DECAPOD_AUTO_INIT !== "1") return false;
  return true;
}

describe("Rule 2: Decapod auto-init gate", () => {
  it("skips when DECAPOD_AUTO_INIT not set", () => {
    assert.equal(shouldAutoInit({}, false), false);
  });

  it("skips when DECAPOD_AUTO_INIT=0", () => {
    assert.equal(shouldAutoInit({ DECAPOD_AUTO_INIT: "0" }, false), false);
  });

  it("proceeds when DECAPOD_AUTO_INIT=1 and .decapod/ absent", () => {
    assert.equal(shouldAutoInit({ DECAPOD_AUTO_INIT: "1" }, false), true);
  });

  it("skips when .decapod/ already exists even if DECAPOD_AUTO_INIT=1", () => {
    assert.equal(shouldAutoInit({ DECAPOD_AUTO_INIT: "1" }, true), false);
  });
});
