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

// =============================================================================
// Configuration
// =============================================================================

const BASE_URL = "https://models.assistant.legogroup.io/anthropic";
const MAX_ERROR_BODY_LENGTH = 200;

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
// Helpers
// =============================================================================

function getApiKey() {
  const key = process.env.MPS_API_KEY;
  if (!key) {
    throw new Error(
      "No API key found. Set the MPS_API_KEY environment variable.\n" +
      "  export MPS_API_KEY=\"<account_id>:<secret>\""
    );
  }
  return key;
}

function sanitizeSurrogates(text) {
  return text.replace(/[\uD800-\uDFFF]/g, "\uFFFD");
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

function convertContentBlocks(content) {
  const hasImages = content.some((c) => c.type === "image");
  if (!hasImages) {
    return sanitizeSurrogates(content.map((c) => c.text).join("\n"));
  }
  return content.map((c) =>
    c.type === "text"
      ? { type: "text", text: sanitizeSurrogates(c.text) }
      : { type: "image", source: { type: "base64", media_type: c.mimeType, data: c.data } }
  );
}

function convertMessages(messages) {
  const params = [];
  for (const msg of messages) {
    if (msg.role === "user") {
      if (typeof msg.content === "string") {
        if (msg.content.trim()) {
          params.push({ role: "user", content: sanitizeSurrogates(msg.content) });
        }
      } else {
        const blocks = msg.content.map((item) =>
          item.type === "text"
            ? { type: "text", text: sanitizeSurrogates(item.text) }
            : { type: "image", source: { type: "base64", media_type: item.mimeType, data: item.data } }
        );
        if (blocks.length > 0) {
          params.push({ role: "user", content: blocks });
        }
      }
    } else if (msg.role === "assistant") {
      const blocks = [];
      for (const block of msg.content) {
        if (block.type === "text" && block.text.trim()) {
          blocks.push({ type: "text", text: sanitizeSurrogates(block.text) });
        } else if (block.type === "thinking" && block.thinking.trim()) {
          if (block.thinkingSignature) {
            blocks.push({
              type: "thinking",
              thinking: sanitizeSurrogates(block.thinking),
              signature: block.thinkingSignature,
            });
          } else {
            blocks.push({ type: "text", text: sanitizeSurrogates(block.thinking) });
          }
        } else if (block.type === "toolCall") {
          blocks.push({
            type: "tool_use",
            id: block.id,
            name: block.name,
            input: block.arguments,
          });
        }
      }
      if (blocks.length > 0) {
        params.push({ role: "assistant", content: blocks });
      }
    } else if (msg.role === "toolResult") {
      params.push({
        role: "user",
        content: [{
          type: "tool_result",
          tool_use_id: msg.toolCallId,
          content: convertContentBlocks(msg.content),
          is_error: msg.isError,
        }],
      });
    }
  }
  return params;
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

function streamAnthropicProxy(model, context, options) {
  const stream = createAssistantMessageEventStream();

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
        messages: convertMessages(context.messages),
        max_tokens: options?.maxTokens ?? Math.floor(model.maxTokens / 3),
        stream: true,
      };

      // Add system prompt
      if (context.systemPrompt) {
        params.system = [{ type: "text", text: sanitizeSurrogates(context.systemPrompt) }];
      }

      // Add tools
      if (context.tools?.length > 0) {
        params.tools = context.tools.map((t) => ({
          name: t.name,
          description: t.description || "",
          input_schema: t.parameters || { type: "object", properties: {} },
        }));
      }

      // Add thinking if model supports it and level is set
      if (model.reasoning && context.thinkingLevel && context.thinkingLevel !== "off") {
        // budget_tokens must be less than max_tokens and positive
        const budget = Math.max(256, Math.min(
          Math.floor(params.max_tokens * 0.8),
          params.max_tokens - 1024
        ));
        params.thinking = {
          type: "enabled",
          budget_tokens: budget,
        };
        params.temperature = 1; // Required by Anthropic API when thinking is enabled
      }

      const url = `${BASE_URL}/v1/messages`;
      const response = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "api-key": apiKey,
          "anthropic-version": "2023-06-01",
          "anthropic-beta": "interleaved-thinking-2025-05-14",
        },
        body: JSON.stringify(params),
        signal: options?.signal,
      });

      if (!response.ok) {
        const errorBody = await response.text();
        // Redact API key from error body in case proxy echoes request headers
        let safeBody = errorBody.slice(0, MAX_ERROR_BODY_LENGTH);
        if (apiKey) {
          safeBody = safeBody.replaceAll(apiKey, "[REDACTED]");
        }
        throw new Error(`HTTP ${response.status}: ${safeBody}`);
      }

      stream.push({ type: "start", partial: output });

      // Map from SSE event index to block object for O(1) lookup
      const blocksByIndex = new Map();
      const reader = response.body.getReader();

      for await (const event of parseSSE(reader)) {
        if (event.type === "message_start") {
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
        }
        // message_stop and ping events are intentionally ignored
      }

      cleanupBlocks(output);
      stream.push({ type: "done", reason: output.stopReason, message: output });
      stream.end();
    } catch (error) {
      cleanupBlocks(output);
      output.stopReason = options?.signal?.aborted ? "aborted" : "error";
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
