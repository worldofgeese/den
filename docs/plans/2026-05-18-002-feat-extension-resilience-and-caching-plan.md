---
title: "feat: Add retry logic, prompt caching, and extension hooks to anthropic-proxy"
status: active
created: 2026-05-18
origin: 10-agent deep review (code-review, adversarial, architecture-strategist, codebase-analyzer, scope-tracer)
depth: standard
---

# feat: Add retry logic, prompt caching, and extension hooks

## Summary

The anthropic-proxy extension currently makes a single attempt per request with no retry logic, no prompt caching, and no extension hook support. This means transient proxy failures (429, 502, 503) immediately surface as errors to the user, every request pays full token costs without cache hits, and other Pi extensions cannot intercept or modify requests. These were identified as P2 items across 10 parallel review agents.

---

## Problem Frame

Three gaps remain after the P0/P1 fixes:

1. **No retry logic** — The LEGO MPS proxy has its own internal retry (3 attempts, 10s backoff), but when it exhausts those and returns a 500/502/503, the extension fails immediately. Pi's own `_isRetryableError` regex catches some patterns (500, 502, timeout), but the extension could handle transient failures more gracefully at the provider level.

2. **No prompt caching** — Anthropic's API supports `cache_control: {type: "ephemeral"}` on system prompts, tools, and the last user message. Without it, every request is a full cache miss — higher latency and cost. The built-in Anthropic provider uses this.

3. **No extension hooks** — Pi's provider contract supports `options.onPayload` and `options.onResponse` callbacks that allow other extensions to modify requests or inspect responses. Our extension ignores these.

---

## Scope Boundaries

### In Scope
- Client-side retry with exponential backoff for transient errors (429, 500, 502, 503)
- Prompt caching via `cache_control` on system prompt and tools
- `onPayload` and `onResponse` callback support
- `output.responseId` capture (already partially done)

### Deferred to Follow-Up Work
- Server-side proxy improvements (that's the LEGO MPS team's domain)
- Full parity with built-in Anthropic provider (OAuth, Vertex, etc.)
- `options.sessionId` for session-affinity routing
- `options.cacheRetention` (short/long/none) — requires proxy support

---

## Key Technical Decisions

1. **Retry at extension level, not delegating to Pi's retry** — Pi retries based on `_isRetryableError` regex matching the error string. But Pi's retry creates a new `streamSimple` call, which rebuilds the full payload. Extension-level retry is cheaper (reuses the already-built `params`) and can be smarter about which errors to retry.

2. **Retry budget: 2 retries, 1s/3s backoff** — The proxy already retried 3 times internally (10s/20s/40s = 70s). If it still fails, a quick client-side retry with short backoff catches transient network issues without adding excessive wait time. Total worst-case: 70s (proxy) + 4s (client) = 74s, well within the 90s fetch timeout.

3. **Prompt caching on system + tools only** — The built-in provider caches system prompt, tools, and the last user message. For simplicity, we'll cache system and tools (which are stable across turns) but skip the last user message (which changes every turn and provides less cache benefit for the added complexity).

4. **onPayload fires before JSON.stringify** — This lets extensions modify the params object (add headers, adjust fields) before serialization. Matches the built-in provider's behavior.

---

## Implementation Units

### U1. Add client-side retry with exponential backoff

**Goal:** Retry transient HTTP errors (429, 500, 502, 503) up to 2 times with 1s/3s backoff before surfacing the error.

**Requirements:** Improve resilience for transient proxy failures without adding excessive latency.

**Dependencies:** None

**Files:**
- `pi-extensions/anthropic-proxy/index.js`

**Approach:**
- Wrap the `fetch()` call in a retry loop
- Only retry on specific status codes: 429, 500, 502, 503
- Do NOT retry if the response was 200 (stream already started) — mid-stream failures are not retryable at this level
- Do NOT retry if the abort signal has fired
- Respect `Retry-After` header if present (429 responses)
- Use `await new Promise(r => setTimeout(r, delay))` for backoff
- Log retries to console.warn for observability

**Patterns to follow:**
- Pi's built-in retry in `settings-manager.js` uses 2000ms base with 3 retries
- The proxy's own retry uses 10s base — our client retry should be much shorter since the proxy already exhausted its budget

**Test scenarios:**
- Happy path: request succeeds on first attempt, no retry triggered
- Retry success: first attempt returns 502, second attempt succeeds — response is delivered normally
- Retry exhausted: all 3 attempts (1 + 2 retries) return 500 — error surfaces to Pi with the last error message
- Abort during retry: signal fires between retry attempts — stops retrying, returns aborted
- Non-retryable error: 400/401/403/406/422 — no retry, immediate error
- 429 with Retry-After: respects the header value (capped at 10s to prevent abuse)

**Verification:** Transient 502/503 errors from the proxy no longer immediately fail the session. Observable via console.warn logs showing retry attempts.

---

### U2. Add prompt caching via cache_control

**Goal:** Reduce latency and cost by enabling Anthropic's prompt caching on stable request components.

**Requirements:** Lower per-request token costs for repeated conversations.

**Dependencies:** None (independent of U1)

**Files:**
- `pi-extensions/anthropic-proxy/index.js`

**Approach:**
- Add `cache_control: { type: "ephemeral" }` to the system prompt block(s)
- Add `cache_control: { type: "ephemeral" }` to the last tool definition in the tools array (Anthropic caches up to and including the marked block)
- Do NOT add cache_control to messages (they change every turn)
- The proxy/Bedrock must support this — if it doesn't, the field is simply ignored (no error)

**Patterns to follow:**
- Built-in Anthropic provider at `providers/anthropic.js` adds cache_control to system, tools, and last user message
- Anthropic docs: cache_control marks the boundary of what to cache

**Test scenarios:**
- Happy path: system prompt and tools include cache_control field in the serialized request
- No system prompt: request still works without cache_control (no crash on undefined)
- No tools: request works without cache_control on tools
- Cache hit observable: `cache_read_input_tokens` in usage response is non-zero on second request with same system/tools
- Verify usage.cacheRead is correctly reported to Pi (already working, just verify cache hits appear)

**Verification:** After two requests with the same system prompt and tools, the second response shows non-zero `cache_read_input_tokens` in the usage data.

---

### U3. Add onPayload and onResponse hook support

**Goal:** Allow other Pi extensions to intercept and modify requests/responses via the standard hook contract.

**Requirements:** Extension interop — other extensions (e.g., `before_provider_request` hooks) can modify the payload or inspect responses.

**Dependencies:** None (independent of U1, U2)

**Files:**
- `pi-extensions/anthropic-proxy/index.js`

**Approach:**
- Before `JSON.stringify(params)`, call `options?.onPayload?.(params)` — this lets extensions modify the params object in-place
- After receiving the response (both success and error paths), call `options?.onResponse?.(response)` — this lets extensions inspect headers (e.g., rate limit headers, request IDs)
- These are fire-and-forget (don't await, don't use return value) to match the built-in provider behavior
- If the callback throws, log a warning but don't fail the request

**Patterns to follow:**
- Built-in Anthropic provider calls `options.onPayload` before sending and `options.onResponse` after receiving
- These are optional callbacks — always use optional chaining

**Test scenarios:**
- Happy path: onPayload is called with the params object before fetch
- Mutation: onPayload modifies params.max_tokens — the modified value is sent to the proxy
- onResponse: called with the Response object after fetch resolves
- No callbacks: when options.onPayload is undefined, request proceeds normally
- Callback throws: error is logged but request continues unaffected

**Verification:** An extension registering `onPayload` can observe and modify the request params. An extension registering `onResponse` can read response headers.

---

### U4. Deploy and verify

**Goal:** Deploy the updated extension and verify all three features work end-to-end.

**Requirements:** All changes deployed and tested in a real Pi session.

**Dependencies:** U1, U2, U3

**Files:**
- `pi-extensions/anthropic-proxy/index.js`
- `modules/shared-devtools.nix` (no changes needed — reads file directly)

**Approach:**
- Run `just deploy-mahakala-hm` to rebuild home-manager
- Test retry: simulate by checking console output during normal operation (retries only fire on errors)
- Test caching: make two identical requests and check `cache_read_input_tokens` in session file
- Test hooks: verify no regression (hooks are opt-in, won't affect normal operation)
- Push to PR #73 on LEGO/agentic-engineering-community

**Test scenarios:**
- Basic request works after all changes
- Thinking mode still works (regression check)
- Tool use still works (regression check)
- Usage data shows cache hits on repeated requests
- No new errors in console output

**Verification:** All existing tests pass. Cache hits observable in session usage data. PR updated.

---

## System-Wide Impact

- **Cost reduction:** Prompt caching should reduce input token costs by 50-90% for repeated conversations (system prompt + tools are cached)
- **Reliability improvement:** Client-side retry catches transient network/proxy issues that currently surface as errors
- **Extension ecosystem:** onPayload/onResponse enables other extensions to work with our provider

---

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Proxy doesn't support cache_control | Field is ignored by non-supporting backends — no error, just no benefit |
| Retry masks persistent failures | Limited to 2 retries with short backoff; overflow detection still fires on large contexts |
| onPayload mutation causes unexpected behavior | Callbacks are opt-in; if they break things, the extension author is responsible |

---

## Deferred Implementation Notes

- Exact retry timing may need tuning based on real-world proxy behavior
- If Bedrock starts returning `Retry-After` headers through the proxy, we should respect them
- `options.cacheRetention` support depends on whether the proxy passes through Anthropic's cache TTL controls
