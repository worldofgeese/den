# MPS Proxy Error Path Analysis

**Date:** 2026-05-18
**Source:** `/tmp/worldofgeese-genai-model-proxy-service/` (LEGO/worldofgeese-genai-model-proxy-service)
**Extension:** `pi-extensions/anthropic-proxy/index.js`

---

## Architecture Summary

The Pi extension hits: `POST https://models.assistant.legogroup.io/anthropic/v1/messages`

This routes to `router/anthropic/messages/main.py` → `post_call_model_anthropic()`.

The request flow is:
1. **Authentication** (`authorize_anthropic_consumer`) — validates `api-key` header
2. **Timeout wrapper** (`asyncio.timeout(call_timeout_sec)`) — default 60s, max 120s
3. **fetch_anthropic_response()** — creates `AsyncAnthropicBedrock` client, retries with backoff, optional fallback
4. **Streaming** — `process_stream_response()` yields SSE events from Bedrock

**Important:** There is also a `/claude/v1/messages` endpoint (for Claude Code via Bearer auth) with different behavior — notably it returns a **fake 200 JSON response** for "prompt is too long" errors instead of an HTTP error. Our extension uses the `/anthropic/v1/messages` endpoint with `api-key` header, NOT the Claude endpoint.

---

## 1. ALL Ways the Proxy Returns HTTP 500

### 1a. Generic catch-all in `fetch_anthropic_response()` (line ~280)

```python
except Exception as e:
    raise HTTPException(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        detail="Internal server error",
    ) from e
```

**Triggers:** ANY unhandled exception in the entire fetch flow that isn't already caught. This includes:
- Network errors connecting to Bedrock
- AWS credential failures
- Unexpected response types from the Anthropic SDK
- Any bug in the normalization functions

**Critical:** The `detail` is hardcoded to `"Internal server error"` — the actual exception message is SWALLOWED.

### 1b. "All retry attempts failed" in `fetch_anthropic_response()` (line ~240)

```python
raise HTTPException(
    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
    detail=f"All retry attempts failed: {str(last_exception)}",
) from last_exception
```

**Triggers:** When both the primary model (3 backoff attempts) AND the fallback model (2 attempts) all fail. The `last_exception` string IS included in the detail.

### 1c. "Unknown response" in the router (line ~90)

```python
raise HTTPException(
    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
    detail="Unknown response",
)
```

**Triggers:** When `fetch_anthropic_response` returns something that is neither `AsyncStream`, `StreamWithClient`, nor `Message`. Should be extremely rare.

### 1d. Re-raised from `post_call_model_anthropic()` catch-all (line ~85)

```python
except Exception as e:
    raise HTTPException(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e)
    ) from e
```

**Triggers:** Any exception that escapes `fetch_anthropic_response` that isn't already an HTTPException. This includes the HTTPExceptions from 1a/1b (which are re-raised), but also any other exception. The `str(e)` preserves the message here.

**Note:** When `fetch_anthropic_response` raises an HTTPException, FastAPI's exception handling re-raises it directly — it doesn't wrap it again. So the outer `except Exception` catches non-HTTPException errors.

---

## 2. Other HTTP Status Codes

| Status | Source | Detail | When |
|--------|--------|--------|------|
| **400** | `authorize_anthropic_consumer` | `"Invalid request body: {e}"` | Malformed JSON in request body |
| **400** | `authenticate_account` | `"Malformed api-key"` | API key doesn't contain `:` separator |
| **402** | `daily_limit_handler` (global) | `"permission_error"` message | Daily USD spend limit exceeded (Claude endpoint only — NOT our path) |
| **403** | `authenticate_account` | `"Forbidden"` | Account not found, or API key mismatch |
| **403** | `FrontDoorMiddleware` | `"Forbidden"` | Missing/wrong `X-Azure-FDID` header (production only) |
| **406** | `authorize_anthropic_consumer` | `"Not found any available model"` | Model not provisioned for account |
| **408** | `post_call_model_anthropic` | `"Request timed out after {N} seconds"` | `asyncio.timeout` fires (default 60s) |
| **422** | `post_call_model_anthropic` | `"Prompt cannot be empty"` | Empty messages array |
| **422** | Pydantic validation | Auto-generated | Payload fails `AnthropicMessagesPayload` validation (e.g., `max_tokens < 1`, `temperature > 1.0`) |
| **500** | Multiple (see section 1) | Various | See above |
| **502** | `authenticate_account` | `"Failed to fetch account model"` | TimeoutError fetching account from cache/DB |

**Notable absences:**
- **No 413** — the proxy has NO request body size limit enforcement
- **No 429** — the proxy has NO rate limiting for the `/anthropic/v1/messages` path (rate limits exist only for "external" role accounts, and only in the queue-based flow which Anthropic doesn't use)
- **No 503** — never explicitly returned

---

## 3. Retry Logic

### Backoff Configuration (from `conf.json`)
- `base_seconds`: 10
- `max_retries`: 3 (so attempts 0, 1, 2)
- `max_wait`: 120 seconds

### Retry Schedule
- Attempt 1: immediate
- Attempt 2: wait min(10 * 2^0, 120) = 10s
- Attempt 3: wait min(10 * 2^1, 120) = 20s

### Errors That SKIP Retries (immediate failure)
1. `"prompt is too long"` in error string → breaks immediately
2. `"web_search"` or `"web_search_20250305"` in error string → breaks immediately

### Errors That Cause Retries
ALL other exceptions from `client.messages.create()`, including:
- `ThrottlingException` (Bedrock rate limit)
- `ModelTimeoutException`
- `ValidationException`
- `ServiceUnavailableException`
- Network errors (connection reset, DNS failure)
- Any other Bedrock/AWS SDK error

### Fallback Logic
After 3 backoff attempts fail, IF the model has a fallback mapping:
- `claude-sonnet-4-5` → falls back to `claude-sonnet-4`
- `claude-haiku-4-5` → falls back to `claude-3-haiku`

Fallback gets 2 additional attempts with the same backoff schedule.

**Total worst-case latency:** 3 attempts × (10s + 20s) + 2 fallback attempts × (10s + 20s) = 150s. But the `asyncio.timeout(60s)` in the router fires first, so the ACTUAL max is **60 seconds** before HTTP 408.

---

## 4. Request Payload Modification

The proxy DOES modify the request before forwarding to Bedrock:

### 4a. Model ID Prefixing
All inference profile models get `"eu."` prepended:
```python
if kw_args["model"] in INFERENCE_PROFILE_MODELS:
    kw_args["model"] = "eu." + kw_args["model"]
```

### 4b. Cache Control Removal (Haiku 3 only)
For `anthropic.claude-3-haiku-20240307-v1:0`:
- `cache_control` is popped from the top-level payload
- System field: list format → joined string
- Messages: `cache_control` removed from content blocks

### 4c. Automatic Cache Control Injection
For all other models, `apply_automatic_cache_control()` adds `{"type": "ephemeral"}` breakpoints to:
- Last content block of last message
- Last system block
- Last tool definition

### 4d. System Field Normalization
`normalize_system_field()` strips `cache_control` from system blocks and converts list format to a joined string. **This is called for Haiku 3 fallback only.**

### 4e. Content Field Normalization
`normalize_content_field()` removes `"caller"` fields from content blocks and strips `tool_reference` type items from tool results.

### 4f. Temperature Removal (Opus 4.7)
For `anthropic.claude-opus-4-7`, `temperature` is popped from kwargs.

### 4g. No Truncation
The proxy does NOT truncate messages, reduce token counts, or remove content. It passes the full payload through (with the above normalizations).

---

## 5. Request Size Limits

### In the Proxy Code: NONE
- No `max_content_length` configuration
- No body size middleware
- No explicit check on message count or content length
- Pydantic only validates field types/ranges, not total size

### In the Infrastructure Layer (likely but not in code)
- Azure Front Door may impose limits (typically 100MB for streaming)
- Uvicorn default: no body size limit
- The proxy runs behind Azure Front Door (`X-Azure-FDID` check)

### Effective Limit
The real limit is Bedrock's context window (200K tokens for Claude models). The proxy will happily forward a 50MB request to Bedrock, which will reject it with "prompt is too long".

---

## 6. "Prompt is Too Long" — Exact Code Path

1. Extension sends request to `/anthropic/v1/messages`
2. `fetch_anthropic_response()` calls `client.messages.create(**kw_args)`
3. Bedrock returns an error containing "prompt is too long"
4. The Anthropic SDK raises an exception with that message
5. The retry loop checks: `if "prompt is too long" in error_str:` → **breaks immediately** (no retries)
6. After the loop, `response is None` → enters the "all retry attempts failed" block
7. **BUT WAIT** — the code path after the `break` for "prompt is too long" falls through to the fallback check:
   ```python
   if response is None and original_model in FALLBACK_MODELS:
   ```
   If the model HAS a fallback (Sonnet 4.5 → Sonnet 4, Haiku 4.5 → Haiku 3), it will try the fallback model with the SAME oversized payload — which will also fail with "prompt is too long".

8. After fallback also fails (or if no fallback exists):
   ```python
   raise HTTPException(
       status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
       detail=f"All retry attempts failed: {str(last_exception)}",
   )
   ```
   The `last_exception` contains the "prompt is too long" text.

9. This HTTPException propagates up to the router's `except Exception as e:` block, which re-raises it.

10. FastAPI returns: `HTTP 500` with body `{"detail": "All retry attempts failed: <bedrock error containing 'prompt is too long'>"}`

**HOWEVER** — there's a second path. If the exception from step 4 is NOT caught by the retry loop (e.g., it's a different exception type that doesn't convert to string cleanly), it falls to the outer `except Exception` in `fetch_anthropic_response`:
```python
raise HTTPException(
    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
    detail="Internal server error",
)
```
In this case, the "prompt is too long" message is SWALLOWED.

### What Our Extension Sees

For the "prompt is too long" case, the extension receives:
- **HTTP 500**
- **Body:** `{"detail": "All retry attempts failed: <error with 'prompt is too long'>"}`

Our extension's `isLikelyContextOverflow()` checks:
1. Status is 500 ✓
2. Error body matches `GENERIC_500_PATTERNS`: checks for `/all retry attempts failed/i` ✓
3. Estimated tokens > 80% of context window

**ISSUE:** The pattern `"All retry attempts failed"` IS in our `GENERIC_500_PATTERNS`, so the heuristic triggers. But the detail ALSO contains "prompt is too long" — we could match that directly instead of relying on the heuristic.

---

## 7. Rate Limiting / Throttling

### In the Proxy: NONE for `/anthropic/v1/messages`
The proxy has rate limit configuration in `conf.json` under `roles.limits.external`, but this is only applied to the queue-based OpenAI flow, not the direct Anthropic path.

### At Bedrock Level
Bedrock has its own throttling (`ThrottlingException`). When this happens:
- The proxy retries with exponential backoff (10s, 20s, 40s...)
- If all retries fail → HTTP 500 with "All retry attempts failed: ThrottlingException..."
- Our extension sees this as a generic 500

### At Azure Front Door Level
Azure Front Door may have its own rate limiting configured externally. This would return a 429 or 503 before the request reaches the proxy.

---

## 8. Timeout Handling

### Layer 1: Extension's `fetch()` — NO TIMEOUT
The extension's `fetch()` call has NO `signal` timeout (only the user-provided `options?.signal` for abort). If the proxy hangs, the extension hangs forever.

### Layer 2: Proxy's `asyncio.timeout()` — 60 seconds (default)
```python
async with asyncio.timeout(call_timeout_sec):  # default: 60s, max: 120s
```
Returns HTTP 408: `"Request timed out after 60 seconds"`

### Layer 3: Backoff Sleep Time
The retry loop can sleep up to 120s between attempts. Combined with the 60s timeout, the timeout will fire DURING retries if backoff exceeds it.

**Race condition:** If the first attempt takes 50s and fails, then backoff sleeps 10s (total 60s), the timeout fires and returns 408 — even though retry #2 hasn't started yet.

### Layer 4: Bedrock's Own Timeout
Bedrock has internal timeouts (typically 60-120s for large prompts). If Bedrock times out, the Anthropic SDK raises an exception, which triggers the retry loop.

### What Our Extension Sees
- HTTP 408 with `"Request timed out after 60 seconds"` — our extension treats this as `HTTP 408: Request timed out...` error message, which does NOT match any overflow pattern. This is correct behavior.

---

## 9. Partial Success Then Error (200 with error in SSE stream)

### YES — This Can Happen

The proxy returns `StreamingResponse` immediately after getting the stream object from Bedrock. The HTTP 200 status is sent BEFORE any SSE events are processed.

In `process_stream_response()`:
```python
try:
    async for event in response:
        ...
        yield await format_event_for_streaming_response(event)
except Exception as e:
    logger.error("[%s] Failed to process response: %s", job.id, str(e))
    background_tasks.add_task(job.register, QueuedJobStatus.ENDPOINT_ERROR, ...)
```

**If an exception occurs mid-stream:**
1. The HTTP 200 has already been sent
2. Some SSE events have already been yielded to the client
3. The exception is caught, logged, and the generator simply STOPS
4. **No error event is yielded to the client** — the stream just ends abruptly

### What Our Extension Sees

The SSE parser (`parseSSE`) is reading from `response.body.getReader()`. If the stream ends abruptly:
1. `reader.read()` returns `{ done: true }` 
2. The parser processes any remaining buffer and returns
3. The `for await` loop exits normally
4. The extension proceeds to `stream.push({ type: "done", ... })`

**CRITICAL BUG:** If the stream ends mid-response without a `message_stop` event:
- `output.stopReason` remains the default `"stop"` (never updated by `message_delta`)
- The extension reports success with whatever partial content was received
- Pi sees a "successful" response with truncated output
- No error is surfaced to the user

### Scenarios That Cause Mid-Stream Failure
- Bedrock connection drops
- Proxy process crashes/restarts
- Azure Front Door timeout (if longer than initial response time)
- Memory pressure causing the proxy to be OOM-killed
- Network partition between proxy and Bedrock after stream starts

---

## Extension Error Handling Coverage Matrix

| Error Scenario | HTTP Status | Detail Pattern | Extension Handles? | Notes |
|---|---|---|---|---|
| Context overflow (prompt too long) | 500 | `"All retry attempts failed: ...prompt is too long..."` | **PARTIAL** — heuristic detects via `GENERIC_500_PATTERNS` + size check | Could match "prompt is too long" directly in the detail |
| Context overflow (swallowed) | 500 | `"Internal server error"` | **PARTIAL** — heuristic detects if context > 80% | False negatives when context is 60-80% but still overflows |
| Bedrock throttling (all retries fail) | 500 | `"All retry attempts failed: ThrottlingException..."` | **NO** — treated as generic error, could trigger false-positive overflow detection if context is large | Should detect "ThrottlingException" and NOT rewrite as overflow |
| Bedrock service unavailable | 500 | `"All retry attempts failed: ServiceUnavailable..."` | **NO** — same as throttling | |
| Request timeout | 408 | `"Request timed out after 60 seconds"` | **YES** — passes through as `HTTP 408: ...` error | Correct — not an overflow |
| Auth failure | 403 | `"Forbidden"` | **YES** — passes through as `HTTP 403: Forbidden` | Correct |
| Model not available | 406 | `"Not found any available model"` | **YES** — passes through | Correct |
| Invalid request body | 400 | `"Invalid request body: ..."` | **YES** — passes through | Correct |
| Pydantic validation | 422 | Auto-generated | **YES** — passes through | Correct |
| Empty messages | 422 | `"Prompt cannot be empty"` | **YES** — passes through | Correct |
| Network drop (no response) | N/A | fetch() rejects | **YES** — caught by try/catch, emits error event | But NO timeout means infinite hang if TCP stays open |
| Mid-stream failure | 200 (already sent) | Stream ends abruptly | **NO** — extension reports success with partial content | **CRITICAL** — silent data loss |
| Proxy returns unknown response type | 500 | `"Unknown response"` | **YES** — passes through as generic 500 | Heuristic may false-positive if context is large |
| AWS credential failure | 500 | `"Internal server error"` | **PARTIAL** — heuristic may false-positive | |
| Daily spend limit (Claude endpoint only) | 402 | Permission error JSON | **N/A** — we don't use the Claude endpoint | |
| Azure Front Door block | 403 | `"Forbidden"` (plain text, not JSON) | **PARTIAL** — `response.text()` may not parse as expected JSON | |
| Unsupported tool (web_search) | 500 | `"All retry attempts failed: ...web_search..."` | **NO** — treated as generic error | Should detect and surface clearly |

---

## Critical Gaps in Extension Error Handling

### Gap 1: No Fetch Timeout (SEVERITY: HIGH)
The extension's `fetch()` has no timeout. If the proxy accepts the TCP connection but never responds (e.g., proxy is overloaded, connection pool exhausted), the extension hangs forever. The Pi session becomes unresponsive.

**Fix:** Add `AbortSignal.timeout(90000)` (90s, slightly above proxy's 60s default + network latency).

### Gap 2: Mid-Stream Failure Detection (SEVERITY: HIGH)
If the SSE stream ends without a `message_stop` event, the extension reports success with partial content. This causes silent data loss — Pi may act on incomplete tool call JSON or truncated text.

**Fix:** Track whether `message_stop` was received. If the stream ends without it, emit an error event instead of "done".

### Gap 3: False-Positive Overflow Detection for Throttling (SEVERITY: MEDIUM)
When Bedrock throttles and all retries fail, the detail contains "All retry attempts failed" which matches `GENERIC_500_PATTERNS`. If the context happens to be >80% of the window, the extension incorrectly rewrites this as "prompt is too long" and triggers compaction — which won't help because the real issue is throttling.

**Fix:** Before applying the overflow heuristic, check if the error detail contains known non-overflow indicators: "ThrottlingException", "ServiceUnavailable", "rate limit", "Too many requests".

### Gap 4: No Retry on Transient Errors (SEVERITY: MEDIUM)
The extension does zero retries. If the proxy returns 408 (timeout) or 500 (transient Bedrock issue), the extension immediately fails. The proxy already retries internally, but a single additional retry at the extension level for 408/500 would improve resilience.

### Gap 5: Overflow Detection Misses Direct Match (SEVERITY: LOW)
The "All retry attempts failed" detail INCLUDES the original "prompt is too long" text from Bedrock. The extension could match this directly instead of relying on the size heuristic, which would be more reliable and avoid false positives.

**Fix:** Add `"prompt is too long"` to the error body check BEFORE the heuristic. If the detail contains this phrase, immediately throw the overflow error regardless of estimated context size.

### Gap 6: Cache Control Stripping May Cause Unexpected Behavior (SEVERITY: LOW)
The proxy strips `cache_control` from system blocks and converts list-format system prompts to a joined string (for Haiku 3). For other models, it injects automatic cache breakpoints. This is invisible to the extension but means caching behavior differs from what the extension requests.

---

## Timeout Budget Analysis

```
Extension fetch() timeout:     NONE (infinite)
Proxy asyncio.timeout:         60s (default), 120s (max, via query param)
Proxy backoff schedule:        10s + 20s + 40s = 70s (exceeds 60s timeout!)
Bedrock response time:         Variable (1-120s for large prompts)
```

**The backoff schedule (70s total) exceeds the default timeout (60s).** This means:
- If the first attempt fails quickly (e.g., throttled in 1s), the proxy has time for 2-3 retries
- If the first attempt takes 30s+ before failing, the timeout fires during the first backoff sleep
- The timeout is a hard ceiling that cuts through the retry logic

---

## Recommendations Priority

1. **Add fetch timeout** (90s) — prevents infinite hangs
2. **Detect incomplete streams** — check for `message_stop` event before declaring success
3. **Direct "prompt is too long" matching** — check error body for this phrase before heuristic
4. **Exclude throttling from overflow heuristic** — prevent false-positive compaction
5. **Consider single retry for 408/500** — improves resilience for transient failures
