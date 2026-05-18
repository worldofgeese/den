---
title: "fix: Enable auto-compaction when proxy returns generic 500 on context overflow"
status: active
created: 2026-05-18
type: fix
depth: standard
origin: debugging session — Pi session stuck in 500 loop
---

# fix: Enable auto-compaction when proxy returns generic 500 on context overflow

---

## Problem Frame

Pi's auto-compaction relies on `isContextOverflow()` from `@mariozechner/pi-ai` to detect when the context window is exceeded. This function pattern-matches against known error messages (e.g., "prompt is too long", "request_too_large", "exceeds the context window").

Our LEGO MPS proxy (`models.assistant.legogroup.io`) wraps all Bedrock errors — including context overflow — into a generic `HTTP 500: {"detail":"500: Internal server error"}`. This matches **none** of the overflow patterns, so:

1. **Case 1 (overflow detection)** fails — `isContextOverflow()` returns `false`
2. **Case 2 (threshold compaction)** also fails — the extension reports `usage: {input: 0, output: 0, ...}` on error responses, so `estimateContextTokens()` has no usage data to work with

The result: Pi enters a death spiral where every request fails with 500, compaction never triggers, and the session is permanently stuck.

**Why the "34.5% utilization" display is misleading:** Pi's context meter uses the `usage` data from the last *successful* response. But the conversation grew significantly after that response (user messages, tool results, custom messages) without ever getting a successful API response back. The actual context size far exceeds the displayed percentage.

---

## Scope Boundaries

### In Scope
- Fix the Pi extension (`pi-extensions/anthropic-proxy/index.js`) to enable auto-compaction
- Ensure Pi's `isContextOverflow()` can detect overflow from our proxy

### Out of Scope / Deferred
- Fixing the proxy itself to return proper 400/413 errors (that's a separate upstream change to the genai-model-proxy-service)
- Changing Pi core's `isContextOverflow()` patterns (we don't control that)
- Adding pre-flight token counting to prevent overflow entirely (follow-up optimization)

### Deferred to Follow-Up Work
- Upstream PR to genai-model-proxy-service to propagate Bedrock's "prompt is too long" error through the detail field instead of swallowing it
- Pre-flight token estimation to warn/compact before hitting the proxy

---

## Key Technical Decisions

1. **Rewrite the error message in the extension** rather than modifying Pi core. The extension owns the `streamSimple` implementation and can intercept the error before Pi's `isContextOverflow()` sees it. This is the only approach that works without forking Pi.

2. **Use a heuristic combining HTTP 500 + estimated context size** to detect likely overflow. When the proxy returns a generic 500 AND the conversation context is large (estimated from message content), rewrite the error message to match one of Pi's known overflow patterns.

3. **Target the "prompt is too long" pattern** specifically, since that's what Anthropic/Bedrock natively returns and Pi already handles it. The rewritten message will be: `"prompt is too long: request failed (context likely exceeds ${contextWindow} token limit)"`.

4. **Estimate context size from the messages array** passed to `streamSimple`. The `context.messages` array is available at call time — we can estimate tokens using a chars/4 heuristic (same as Pi's internal `estimateTokens`).

---

## Implementation Units

### U1. Add context size estimation helper

**Goal:** Create a function that estimates the token count of the messages being sent to the API, so we can detect when a 500 is likely caused by context overflow.

**Requirements:** Enable heuristic overflow detection when the proxy returns generic errors.

**Dependencies:** None

**Files:**
- `pi-extensions/anthropic-proxy/index.js`

**Approach:** Add an `estimateMessageTokens(messages, systemPrompt, tools)` function that uses the chars/4 heuristic (matching Pi's internal approach). Count characters across all message content blocks, system prompt, and tool definitions. Return an estimated token count.

**Patterns to follow:** Pi's own `estimateTokens` in `compaction.js` uses `chars / 4` as a conservative estimate.

**Test scenarios:**
- Empty messages array returns 0
- Single short user message estimates correctly (~chars/4)
- Messages with image blocks count the base64 data
- System prompt tokens are included in the estimate
- Tool definitions are included in the estimate

**Verification:** Function returns reasonable estimates when called with typical Pi conversation payloads.

---

### U2. Detect and rewrite generic 500 as overflow when context is large

**Goal:** When the proxy returns HTTP 500 with a generic error AND the estimated context exceeds a threshold, rewrite the error message to match Pi's `isContextOverflow()` pattern so auto-compaction triggers.

**Requirements:** Pi's auto-compaction must trigger when our proxy swallows a context overflow into a generic 500.

**Dependencies:** U1

**Files:**
- `pi-extensions/anthropic-proxy/index.js`

**Approach:** In the `streamAnthropicProxy` function's error handling path (after `if (!response.ok)`), add logic:

1. If `response.status === 500` AND the error body matches the generic pattern (`"Internal server error"` or `"All retry attempts failed"`):
2. Estimate the context size using U1's helper
3. If estimated tokens > `model.contextWindow * 0.8` (80% threshold — conservative to avoid false positives while catching the common case):
4. Rewrite the error message to: `"prompt is too long: request failed (context likely exceeds ${model.contextWindow} token limit)"`
5. Otherwise, pass through the original error unchanged

The 80% threshold accounts for the chars/4 heuristic being imprecise — we want to catch genuine overflow without triggering on unrelated 500s when context is small.

**Patterns to follow:** The existing error handling in `streamAnthropicProxy` already reads the error body and constructs the error message. We're adding a conditional rewrite before the `throw new Error(...)`.

**Test scenarios:**
- HTTP 500 + "Internal server error" + context > 80% of window → error rewritten to "prompt is too long: ..."
- HTTP 500 + "Internal server error" + context < 80% of window → original error preserved
- HTTP 500 + "All retry attempts failed" + large context → error rewritten
- HTTP 400 + any error → NOT rewritten (only 500s are ambiguous)
- HTTP 500 + specific error (e.g., "rate limit") → NOT rewritten (only generic messages)
- HTTP 413 + any error → NOT rewritten (already a clear signal)

**Verification:** After this change, a Pi session that hits the proxy's generic 500 due to context overflow will see `isContextOverflow()` return `true`, triggering auto-compaction.

---

### U3. Propagate usage data on successful responses for threshold compaction

**Goal:** Ensure Pi's threshold-based compaction (Case 2) works by correctly reporting `input` token counts from the proxy's response, so `shouldCompact()` can trigger *before* overflow occurs.

**Requirements:** Pi should auto-compact at ~80% context utilization, not wait until overflow.

**Dependencies:** None (independent of U1/U2)

**Files:**
- `pi-extensions/anthropic-proxy/index.js`

**Approach:** The extension already parses `message_start` events to extract `usage.input_tokens`. Verify that `output.usage.input` is correctly populated from the streaming response's `usage` field. The proxy returns Bedrock-style usage in `RawMessageStartEvent` and `RawMessageDeltaEvent`. Ensure both `input_tokens` and `cache_read_input_tokens` are captured so `calculateContextTokens()` in Pi core computes the correct total.

Currently the extension captures:
```
output.usage.input = event.message.usage.input_tokens
output.usage.cacheRead = event.message.usage.cache_read_input_tokens
```

Verify this is working correctly by checking the SSE event format from our proxy (which may differ from direct Anthropic API in field naming due to Bedrock passthrough).

**Patterns to follow:** The existing `message_start` and `message_delta` event handling in the extension's SSE parser.

**Test scenarios:**
- Successful streaming response populates `output.usage.input` with correct token count
- `cache_read_input_tokens` (if present) populates `output.usage.cacheRead`
- `output.usage.totalTokens` is computed as sum of all usage fields
- After a successful response, Pi's context meter shows accurate utilization percentage

**Verification:** After a successful response, `output.usage.input` is non-zero and reflects the actual input token count reported by the proxy. Pi's status bar shows accurate context utilization.

---

### U4. Update home-manager Nix configuration

**Goal:** Ensure the updated extension source is properly deployed via home-manager.

**Requirements:** Changes to the extension source must be picked up by the Nix build.

**Dependencies:** U1, U2, U3

**Files:**
- `pi-extensions/anthropic-proxy/index.js`
- Any home-manager Nix module that references this file

**Approach:** The extension is symlinked from the Nix store (`/nix/store/wfam6imx0yw26a6sv39d5ffm0mm2ycqv-home-manager-files/...`). After editing the source in `pi-extensions/anthropic-proxy/index.js`, run `home-manager switch` to rebuild and deploy.

**Test expectation: none** — this is a deployment step, not a behavioral change.

**Verification:** After `home-manager switch`, `readlink ~/.pi/agent/extensions/anthropic-proxy/index.js` points to the new store path, and starting Pi shows `[anthropic-proxy] Loaded 3 model(s)` without errors.

---

## System-Wide Impact

- **Pi auto-compaction:** Will now trigger correctly when the proxy returns generic 500s on context overflow. Sessions will no longer get permanently stuck.
- **False positive risk:** The 80% threshold is conservative. A session at 80%+ context that hits a *non-overflow* 500 (e.g., AWS outage) would trigger unnecessary compaction. This is acceptable — compaction is non-destructive and the session recovers either way.
- **Context meter accuracy:** U3 ensures the utilization display is accurate, giving users earlier warning before overflow.

---

## Risks and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| False positive: non-overflow 500 triggers compaction | Low | 80% threshold + generic message check limits false positives. Compaction is non-destructive. |
| chars/4 heuristic underestimates (images, tools) | Medium | Use conservative 80% threshold rather than 95%+. Images are base64 so chars/4 actually overestimates for them. |
| Proxy changes error format in future | Low | The check is additive — if the proxy starts returning proper errors, Pi's native patterns will match first and this code becomes a no-op. |

---

## Deferred Implementation Notes

- The ideal fix is upstream: make the proxy propagate Bedrock's actual error message in the `detail` field. Then Pi's native "prompt is too long" pattern would match without any extension-side heuristic.
- A pre-flight token count (using tiktoken or the proxy's tokenizer endpoint) could prevent overflow entirely by requesting compaction *before* sending the request. This is a future optimization.
