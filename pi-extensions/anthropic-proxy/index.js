/**
 * Anthropic Proxy Provider Extension for Pi
 *
 * Full custom streamSimple implementation using raw fetch() — no external
 * dependencies needed. Handles thinking/reasoning blocks correctly through
 * a LiteLLM/Bedrock proxy.
 *
 * Authentication: MPS_API_KEY environment variable
 * Models: loaded from models.json in this extension's directory
 *
 * Usage:
 *   MPS_API_KEY=<your-key> pi --provider anthropic-proxy
 *   pi --provider anthropic-proxy --model "Opus 4.6"
 */

import {
  createAssistantMessageEventStream,
  calculateCost,
} from "@mariozechner/pi-ai";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { convertMessages, sanitizeSurrogates } from "./message-conversion.js";

// =============================================================================
// Configuration
// =============================================================================

const BASE_URL = "https://models.assistant.legogroup.io/anthropic";
const MAX_ERROR_BODY_LENGTH = 200;
const RETRY_DELAYS = [1000, 3000]; // 2 retries: 1s, 3s backoff
const RETRYABLE_STATUS_CODES = new Set([429, 500, 502, 503]);

const __dirname = dirname(fileURLToPath(import.meta.url));

// =============================================================================
// Models Configuration
// =============================================================================



function loadModels() {
  const modelsPath = join(__dirname, "models.json");
  try {
    const raw = readFileSync(modelsPath, "utf-8");
    const models = JSON.parse(raw);
    if (!Array.isArray(models)) {
      console.warn("[anthropic-proxy] models.json must be a JSON array. Got:", typeof models);
      return [];
    }
    const valid = models.filter((m, i) => {
      if (!m.id || !m.name || !m.maxTokens || !m.contextWindow) {
        console.warn(`[anthropic-proxy] models.json[${i}] missing required field — skipping`);
        return false;
      }
      if (typeof m.maxTokens !== "number" || m.maxTokens <= 0) {
        console.warn(`[anthropic-proxy] models.json[${i}] "maxTokens" must be positive — skipping`);
        return false;
      }
      return true;
    });
    console.log(`[anthropic-proxy] Loaded ${valid.length} model(s) from models.json`);
    return valid;
  } catch (err) {
    if (err.code === "ENOENT") {
      console.warn(
        "[anthropic-proxy] No models.json found at", modelsPath,
        "\n  Copy models.example.json to models.json and configure your models."
      );
    } else {
      console.warn("[anthropic-proxy] Failed to read models.json:", err.message);
    }
    return [];
  }
}

// =============================================================================
// Context Size Estimation
// =============================================================================

/**
 * Estimate token count for the request payload using chars/4 heuristic.
 * This matches Pi's internal estimateTokens approach and is intentionally
 * conservative (overestimates) to avoid false negatives.
 */
function estimateContextTokens(messages, systemPrompt, tools) {
  let chars = 0;

  // System prompt
  if (systemPrompt) {
    if (typeof systemPrompt === "string") {
      chars += systemPrompt.length;
    } else if (Array.isArray(systemPrompt)) {
      for (const block of systemPrompt) {
        if (block.text) chars += block.text.length;
      }
    }
  }

  // Messages
  if (Array.isArray(messages)) {
    for (const msg of messages) {
      if (typeof msg.content === "string") {
        chars += msg.content.length;
      } else if (Array.isArray(msg.content)) {
        for (const block of msg.content) {
          if (block.type === "text" && block.text) {
            chars += block.text.length;
          } else if (block.type === "image" && block.source?.data) {
            // Base64 images: ~0.75 bytes per char, estimate tokens conservatively
            chars += block.source.data.length;
          } else if (block.type === "thinking" && block.thinking) {
            chars += block.thinking.length;
          } else if (block.type === "tool_use") {
            chars += JSON.stringify(block.input || {}).length;
            chars += (block.name || "").length;
          } else if (block.type === "tool_result") {
            const content = block.content;
            if (typeof content === "string") {
              chars += content.length;
            } else if (Array.isArray(content)) {
              for (const item of content) {
                if (item.text) chars += item.text.length;
              }
            }
          }
        }
      }
    }
  }

  // Tool definitions
  if (Array.isArray(tools)) {
    for (const tool of tools) {
      chars += (tool.name || "").length;
      chars += (tool.description || "").length;
      chars += JSON.stringify(tool.input_schema || {}).length;
    }
  }

  // chars/4 is the standard heuristic (conservative overestimate)
  return Math.ceil(chars / 4);
}

/**
 * Patterns that indicate the proxy's generic error wrapping.
 * These are errors where the actual cause is swallowed into a generic 500.
 */
const GENERIC_500_PATTERNS = [
  /internal server error/i,
  /all retry attempts failed/i,
];

/**
 * Check if an HTTP error is likely a context overflow based on:
 * 1. HTTP 500 status (proxy wraps errors generically)
 * 2. Generic error message (not a specific, actionable error)
 * 3. Estimated context size exceeds threshold
 */
function isLikelyContextOverflow(status, errorBody, estimatedTokens, contextWindow) {
  // Only apply to 500s — other status codes have clear semantics
  if (status !== 500) return false;

  // Only apply when the error message is generic (proxy swallowed the real error)
  const isGenericError = GENERIC_500_PATTERNS.some((p) => p.test(errorBody));
  if (!isGenericError) return false;

  // Only trigger when context is large enough that overflow is plausible
  // 80% threshold: conservative to avoid false positives while catching real overflow
  if (!contextWindow || estimatedTokens < contextWindow * 0.8) return false;

  return true;
}

// =============================================================================
// Helpers
// =============================================================================

function getApiKey() {
  const key = process.env.ANTHROPIC_AUTH_TOKEN || process.env.MPS_API_KEY;
  if (!key) {
    throw new Error(
      "No API key found. Set ANTHROPIC_AUTH_TOKEN environment variable.\n" +
      "  export ANTHROPIC_AUTH_TOKEN=\"<token>\""
    );
  }
  return key;
}

function mapStopReason(reason) {
  switch (reason) {
    case "end_turn":
    case "pause_turn":
    case "stop_sequence":
      return "stop";
    case "max_tokens":
      return "length";
    case "tool_use":
      return "toolUse";
    default:
      return "error";
  }
}

// =============================================================================
// SSE Parser
// =============================================================================

async function* parseSSE(reader) {
  const decoder = new TextDecoder();
  let buffer = "";
  let eventType = null;

  while (true) {
    const { done, value } = await reader.read();

    if (done) {
      // Flush decoder and process any remaining buffered data
      buffer += decoder.decode();
      if (buffer.trim()) {
        const lines = buffer.split("\n");
        for (const line of lines) {
          if (line.startsWith("event: ")) {
            eventType = line.slice(7).trim();
          } else if (line.startsWith("data: ")) {
            const data = line.slice(6);
            if (data === "[DONE]") return;
            try {
              const parsed = JSON.parse(data);
              if (eventType) parsed.type = eventType;
              yield parsed;
            } catch (e) {
              console.warn("[anthropic-proxy] Failed to parse final SSE data:", data.slice(0, 80));
            }
            eventType = null;
          }
        }
      }
      break;
    }

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() || "";

    for (const line of lines) {
      if (line.startsWith("event: ")) {
        eventType = line.slice(7).trim();
      } else if (line.startsWith("data: ")) {
        const data = line.slice(6);
        if (data === "[DONE]") return;
        try {
          const parsed = JSON.parse(data);
          if (eventType) parsed.type = eventType;
          yield parsed;
        } catch (e) {
          console.warn("[anthropic-proxy] Failed to parse SSE data:", data.slice(0, 80));
        }
        eventType = null;
      } else if (line === "") {
        eventType = null;
      }
    }
  }
}

// =============================================================================
// Stream Implementation
// =============================================================================

function cleanupBlocks(output) {
  for (const block of output.content) {
    delete block._partialJson;
  }
}

function sleep(ms, signal) {
  if (!signal) return new Promise((resolve) => setTimeout(resolve, ms));
  if (signal.aborted) return Promise.reject(new DOMException("Request aborted", "AbortError"));

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      signal.removeEventListener("abort", abort);
      resolve();
    }, ms);
    const abort = () => {
      clearTimeout(timeout);
      reject(new DOMException("Request aborted", "AbortError"));
    };
    signal.addEventListener("abort", abort, { once: true });
  });
}

function streamAnthropicProxy(model, context, options = {}) {
  const stream = createAssistantMessageEventStream();
  const streamOptions = options ?? {};

  (async () => {
    const output = {
      role: "assistant",
      content: [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: {
        input: 0,
        output: 0,
        cacheRead: 0,
        cacheWrite: 0,
        totalTokens: 0,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
      },
      stopReason: "stop",
      timestamp: Date.now(),
    };

    try {
      const apiKey = getApiKey();

      // Build request params
      const params = {
        model: model.id,
        messages: convertMessages(context?.messages),
        max_tokens: streamOptions.maxTokens ?? Math.floor(model.maxTokens / 3),
        stream: true,
      };

      // Add system prompt with prompt caching
      if (context?.systemPrompt) {
        params.system = [{
          type: "text",
          text: sanitizeSurrogates(context.systemPrompt),
          cache_control: { type: "ephemeral" },
        }];
      }

      // Add tools with prompt caching on the last tool
      if (context?.tools?.length > 0) {
        params.tools = context.tools.map((t, i) => {
          const tool = {
            name: t.name,
            description: t.description || "",
            input_schema: t.parameters || { type: "object", properties: {} },
          };
          // Cache up to and including the last tool (Anthropic caches the prefix)
          if (i === context.tools.length - 1) {
            tool.cache_control = { type: "ephemeral" };
          }
          return tool;
        });
      }

      // Add thinking if model supports it and reasoning level is set
      if (model.reasoning && streamOptions.reasoning && streamOptions.reasoning !== "off") {
        const defaultBudgets = { minimal: 1024, low: 4096, medium: 10240, high: 16384, xhigh: 32768 };
        const budget = streamOptions.thinkingBudgets?.[streamOptions.reasoning]
          ?? defaultBudgets[streamOptions.reasoning]
          ?? 10240;
        // Ensure budget < max_tokens (API requirement)
        const safeBudget = Math.min(budget, params.max_tokens - 1);
        if (safeBudget > 0) {
          params.thinking = {
            type: "enabled",
            budget_tokens: safeBudget,
          };
          params.temperature = 1; // Required by Anthropic API when thinking is enabled
        }
      }

      // Fire onPayload hook before serialization (lets other extensions modify params)
      try { streamOptions.onPayload?.(params); } catch (e) {
        console.warn("[anthropic-proxy] onPayload hook error:", e.message);
      }

      // Estimate input size to adapt timeouts for large contexts (compaction)
      const estimatedInputTokens = params.messages?.reduce((sum, m) => {
        if (typeof m.content === "string") return sum + m.content.length / 4;
        if (Array.isArray(m.content)) return sum + m.content.reduce((s, b) => s + (b.text?.length || 0) / 4, 0);
        return sum;
      }, 0) || 0;
      const isLargeContext = estimatedInputTokens > 100_000;

      // Proxy has asyncio.timeout(call_timeout_sec) — default 60s, max 120s.
      // Pass max for large requests; use default for normal ones.
      const url = isLargeContext
        ? `${BASE_URL}/v1/messages?call-timeout-sec=120`
        : `${BASE_URL}/v1/messages`;

      // Client timeout: 90s normal, none for large (proxy's 120s is the real limit)
      const signals = isLargeContext
        ? [streamOptions.signal].filter(Boolean)
        : [streamOptions.signal, AbortSignal.timeout(90_000)].filter(Boolean);
      const combinedSignal = signals.length > 1 ? AbortSignal.any(signals) : signals[0] || undefined;

      const requestBody = JSON.stringify(params);
      const requestOptions = {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "api-key": apiKey,
          "anthropic-version": "2023-06-01",
          "anthropic-beta": "interleaved-thinking-2025-05-14",
        },
        body: requestBody,
        signal: combinedSignal,
      };

      // Retry loop for transient errors
      let response;
      let lastError;
      const retryDelays = [...RETRY_DELAYS]; // Copy so Retry-After doesn't mutate global
      for (let attempt = 0; attempt <= retryDelays.length; attempt++) {
        if (attempt > 0) {
          if (combinedSignal?.aborted) break;
          const delay = retryDelays[attempt - 1];
          console.warn(`[anthropic-proxy] Retry ${attempt}/${retryDelays.length} after ${delay}ms`);
          await sleep(delay, combinedSignal);
        }

        try {
          response = await fetch(url, requestOptions);
        } catch (fetchErr) {
          // Network-level failures: DNS timeout, TLS handshake failure,
          // connection refused, UND_ERR_CONNECT_TIMEOUT — these throw
          // TypeError instead of returning an HTTP response.
          const isRetryable = fetchErr.name === "TypeError"
            || fetchErr.cause?.code === "UND_ERR_CONNECT_TIMEOUT"
            || fetchErr.cause?.code === "ECONNREFUSED"
            || fetchErr.cause?.code === "ENOTFOUND"
            || fetchErr.cause?.code === "UND_ERR_SOCKET"
            || /fetch failed|network|socket|ETIMEDOUT/i.test(fetchErr.message);

          if (isRetryable && attempt < retryDelays.length) {
            console.warn(
              `[anthropic-proxy] Network error (attempt ${attempt + 1}/${retryDelays.length + 1}): ${fetchErr.cause?.code || fetchErr.message}`
            );
            lastError = `Network: ${fetchErr.cause?.code || fetchErr.message}`;
            continue; // retry
          }
          // Non-retryable or exhausted retries — rethrow
          throw fetchErr;
        }

        // Fire onResponse hook (lets other extensions inspect headers)
        try { streamOptions.onResponse?.(response); } catch (e) {
          console.warn("[anthropic-proxy] onResponse hook error:", e.message);
        }

        if (response.ok) break;

        // Read error body for classification
        const errorBody = await response.text();
        let safeBody = errorBody.slice(0, MAX_ERROR_BODY_LENGTH);
        if (apiKey) {
          safeBody = safeBody.replaceAll(apiKey, "[REDACTED]");
        }

        // Non-retryable: context overflow (direct match)
        if (/prompt is too long|input is too long|token count exceeds/i.test(safeBody)) {
          throw new Error(`prompt is too long: ${safeBody}`);
        }

        // Non-retryable: context overflow (heuristic)
        const isThrottling = /throttl|rate.?limit|too many requests|service.?unavailable/i.test(safeBody);
        const estimatedTokens = estimateContextTokens(params.messages, params.system, params.tools);
        if (!isThrottling && isLikelyContextOverflow(response.status, safeBody, estimatedTokens, model.contextWindow)) {
          throw new Error(
            `prompt is too long: request failed (context likely exceeds ${model.contextWindow} token limit, estimated ${estimatedTokens} tokens)`
          );
        }

        // Non-retryable status codes: fail immediately
        if (!RETRYABLE_STATUS_CODES.has(response.status)) {
          throw new Error(`HTTP ${response.status}: ${safeBody}`);
        }

        // Retryable: respect Retry-After header (capped at 10s)
        if (response.status === 429 && attempt < retryDelays.length) {
          const retryAfter = parseInt(response.headers.get("retry-after") || "0", 10);
          if (retryAfter > 0 && retryAfter <= 10) {
            retryDelays[attempt] = retryAfter * 1000;
          }
        }

        lastError = `HTTP ${response.status}: ${safeBody}`;
      }

      // If we exhausted retries, throw the last error
      if (!response) {
        if (combinedSignal?.aborted) {
          throw new DOMException("Request aborted", "AbortError");
        }
        throw new Error(lastError || "request failed before receiving a response");
      }

      if (!response.ok) {
        throw new Error(lastError || `HTTP ${response.status}: request failed after retries`);
      }

      if (!response.body) {
        throw new Error("Response body is null — proxy returned empty stream");
      }

      stream.push({ type: "start", partial: output });

      // Map from SSE event index to block object for O(1) lookup
      const blocksByIndex = new Map();
      let receivedMessageStart = false;
      let receivedMessageStop = false;
      const reader = response.body.getReader();

      for await (const event of parseSSE(reader)) {
        if (event.type === "message_start") {
          receivedMessageStart = true;
          output.responseId = event.message?.id;
          const usage = event.message?.usage;
          if (usage) {
            output.usage.input = usage.input_tokens || 0;
            output.usage.output = usage.output_tokens || 0;
            output.usage.cacheRead = usage.cache_read_input_tokens || 0;
            output.usage.cacheWrite = usage.cache_creation_input_tokens || 0;
            output.usage.totalTokens =
              output.usage.input + output.usage.output + output.usage.cacheRead + output.usage.cacheWrite;
            try { calculateCost(model, output.usage); } catch {}
          }
        } else if (event.type === "content_block_start") {
          const cb = event.content_block;
          if (!cb) continue;
          let block;
          if (cb.type === "text") {
            block = { type: "text", text: "" };
            output.content.push(block);
            stream.push({ type: "text_start", contentIndex: output.content.length - 1, partial: output });
          } else if (cb.type === "thinking") {
            block = { type: "thinking", thinking: "", thinkingSignature: "" };
            output.content.push(block);
            stream.push({ type: "thinking_start", contentIndex: output.content.length - 1, partial: output });
          } else if (cb.type === "tool_use") {
            block = { type: "toolCall", id: cb.id, name: cb.name, arguments: {}, _partialJson: "" };
            output.content.push(block);
            stream.push({ type: "toolcall_start", contentIndex: output.content.length - 1, partial: output });
          }
          if (block) {
            blocksByIndex.set(event.index, { block, contentIndex: output.content.length - 1 });
          }
        } else if (event.type === "content_block_delta") {
          const entry = blocksByIndex.get(event.index);
          if (!entry) continue;
          const { block, contentIndex } = entry;

          if (!event.delta) continue;
          if (event.delta.type === "text_delta" && block.type === "text") {
            block.text += event.delta.text;
            stream.push({ type: "text_delta", contentIndex, delta: event.delta.text, partial: output });
          } else if (event.delta.type === "thinking_delta" && block.type === "thinking") {
            block.thinking += event.delta.thinking;
            stream.push({ type: "thinking_delta", contentIndex, delta: event.delta.thinking, partial: output });
          } else if (event.delta.type === "input_json_delta" && block.type === "toolCall") {
            block._partialJson += event.delta.partial_json;
            try {
              block.arguments = JSON.parse(block._partialJson);
            } catch {}
            stream.push({ type: "toolcall_delta", contentIndex, delta: event.delta.partial_json, partial: output });
          } else if (event.delta.type === "signature_delta" && block.type === "thinking") {
            block.thinkingSignature = (block.thinkingSignature || "") + event.delta.signature;
          }
        } else if (event.type === "content_block_stop") {
          const entry = blocksByIndex.get(event.index);
          if (!entry) continue;
          const { block, contentIndex } = entry;

          if (block.type === "text") {
            stream.push({ type: "text_end", contentIndex, content: block.text, partial: output });
          } else if (block.type === "thinking") {
            stream.push({ type: "thinking_end", contentIndex, content: block.thinking, partial: output });
          } else if (block.type === "toolCall") {
            try {
              block.arguments = JSON.parse(block._partialJson);
            } catch (e) {
              console.warn("[anthropic-proxy] Failed to parse final tool arguments for", block.name);
            }
            delete block._partialJson;
            stream.push({ type: "toolcall_end", contentIndex, toolCall: block, partial: output });
          }
          blocksByIndex.delete(event.index);
        } else if (event.type === "message_delta") {
          if (event.delta?.stop_reason) {
            output.stopReason = mapStopReason(event.delta.stop_reason);
          }
          if (event.usage) {
            output.usage.output = event.usage.output_tokens || output.usage.output;
            output.usage.totalTokens =
              output.usage.input + output.usage.output + output.usage.cacheRead + output.usage.cacheWrite;
            try { calculateCost(model, output.usage); } catch {}
          }
        } else if (event.type === "message_stop") {
          receivedMessageStop = true;
        }
        // ping events are intentionally ignored
      }

      // Detect incomplete streams: if we never got message_start, the proxy sent invalid data
      if (!receivedMessageStart) {
        throw new Error("Stream completed without valid SSE data — proxy may have returned an error page");
      }

      // Detect truncated streams: message_start but no message_stop means interrupted
      if (!receivedMessageStop && output.content.length > 0) {
        throw new Error("Stream interrupted — response incomplete (no message_stop received)");
      }

      cleanupBlocks(output);
      blocksByIndex.clear();
      stream.push({ type: "done", reason: output.stopReason, message: output });
      stream.end();
    } catch (error) {
      cleanupBlocks(output);
      const isAborted = streamOptions.signal?.aborted || (error instanceof Error && error.name === "AbortError");
      output.stopReason = isAborted ? "aborted" : "error";
      output.errorMessage = error instanceof Error ? error.message : String(error);
      stream.push({ type: "error", reason: output.stopReason, error: output });
      stream.end();
    }
  })();

  return stream;
}

// =============================================================================
// Extension Entry Point
// =============================================================================

export default function (pi) {
  const models = loadModels();

  pi.registerProvider("anthropic-proxy", {
    name: "Anthropic Proxy",
    baseUrl: BASE_URL,
    apiKey: "managed-by-extension",
    api: "anthropic-proxy-api",
    models,
    streamSimple: streamAnthropicProxy,
  });
}
