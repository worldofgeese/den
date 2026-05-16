/**
 * Anthropic Proxy Provider Extension for Pi
 *
 * Full custom streamSimple implementation using raw fetch() — no external
 * dependencies needed. Handles thinking/reasoning blocks correctly through
 * a LiteLLM/Bedrock proxy.
 *
 * Usage:
 *   pi --provider anthropic-proxy
 *   pi --provider anthropic-proxy --model "Opus 4.6"
 */

import {
  createAssistantMessageEventStream,
  calculateCost,
} from "@mariozechner/pi-ai";
import { execSync } from "node:child_process";

// =============================================================================
// Helpers
// =============================================================================

function getApiKey() {
  try {
    return execSync("gopass show -o dev/anthropic-proxy-key", {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (e) {
    if (process.env.MPS_API_KEY) return process.env.MPS_API_KEY;
    throw new Error(
      "Failed to retrieve API key from gopass. Ensure 'dev/anthropic-proxy-key' exists, or set MPS_API_KEY env var."
    );
  }
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

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    const lines = buffer.split("\n");
    buffer = lines.pop() || "";

    let eventType = null;
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
        } catch {}
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
        max_tokens: options?.maxTokens || Math.floor(model.maxTokens / 3),
        stream: true,
      };

      // Add system prompt
      if (context.systemPrompt) {
        params.system = [{ type: "text", text: context.systemPrompt }];
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
        params.thinking = {
          type: "enabled",
          budget_tokens: Math.min(
            Math.floor(params.max_tokens * 0.8),
            params.max_tokens - 1024
          ),
        };
        params.temperature = 1; // Required for thinking
      }

      const url = `${model.baseUrl}/v1/messages`;
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
        throw new Error(`HTTP ${response.status}: ${errorBody}`);
      }

      stream.push({ type: "start", partial: output });

      const blocks = [];
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
            calculateCost(model, output.usage);
          }
        } else if (event.type === "content_block_start") {
          const cb = event.content_block;
          if (cb.type === "text") {
            output.content.push({ type: "text", text: "", _index: event.index });
            stream.push({ type: "text_start", contentIndex: output.content.length - 1, partial: output });
          } else if (cb.type === "thinking") {
            output.content.push({
              type: "thinking",
              thinking: "",
              thinkingSignature: "",
              _index: event.index,
            });
            stream.push({ type: "thinking_start", contentIndex: output.content.length - 1, partial: output });
          } else if (cb.type === "tool_use") {
            output.content.push({
              type: "toolCall",
              id: cb.id,
              name: cb.name,
              arguments: {},
              _partialJson: "",
              _index: event.index,
            });
            stream.push({ type: "toolcall_start", contentIndex: output.content.length - 1, partial: output });
          }
          blocks.push(output.content[output.content.length - 1]);
        } else if (event.type === "content_block_delta") {
          const index = blocks.findIndex((b) => b._index === event.index);
          const block = blocks[index];
          if (!block) continue;

          if (event.delta.type === "text_delta" && block.type === "text") {
            block.text += event.delta.text;
            stream.push({ type: "text_delta", contentIndex: index, delta: event.delta.text, partial: output });
          } else if (event.delta.type === "thinking_delta" && block.type === "thinking") {
            block.thinking += event.delta.thinking;
            stream.push({
              type: "thinking_delta",
              contentIndex: index,
              delta: event.delta.thinking,
              partial: output,
            });
          } else if (event.delta.type === "input_json_delta" && block.type === "toolCall") {
            block._partialJson += event.delta.partial_json;
            try {
              block.arguments = JSON.parse(block._partialJson);
            } catch {}
            stream.push({
              type: "toolcall_delta",
              contentIndex: index,
              delta: event.delta.partial_json,
              partial: output,
            });
          } else if (event.delta.type === "signature_delta" && block.type === "thinking") {
            block.thinkingSignature = (block.thinkingSignature || "") + event.delta.signature;
          }
        } else if (event.type === "content_block_stop") {
          const index = blocks.findIndex((b) => b._index === event.index);
          const block = blocks[index];
          if (!block) continue;

          delete block._index;
          if (block.type === "text") {
            stream.push({ type: "text_end", contentIndex: index, content: block.text, partial: output });
          } else if (block.type === "thinking") {
            stream.push({ type: "thinking_end", contentIndex: index, content: block.thinking, partial: output });
          } else if (block.type === "toolCall") {
            try {
              block.arguments = JSON.parse(block._partialJson);
            } catch {}
            delete block._partialJson;
            stream.push({ type: "toolcall_end", contentIndex: index, toolCall: block, partial: output });
          }
        } else if (event.type === "message_delta") {
          if (event.delta?.stop_reason) {
            output.stopReason = mapStopReason(event.delta.stop_reason);
          }
          if (event.usage) {
            output.usage.output = event.usage.output_tokens || output.usage.output;
            output.usage.totalTokens =
              output.usage.input + output.usage.output + output.usage.cacheRead + output.usage.cacheWrite;
            calculateCost(model, output.usage);
          }
        }
      }

      // Clean up internal properties
      for (const block of output.content) {
        delete block._index;
        delete block._partialJson;
      }

      stream.push({ type: "done", reason: output.stopReason, message: output });
      stream.end();
    } catch (error) {
      for (const block of output.content) {
        delete block._index;
        delete block._partialJson;
      }
      output.stopReason = options?.signal?.aborted ? "aborted" : "error";
      output.errorMessage = error instanceof Error ? error.message : JSON.stringify(error);
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
  pi.registerProvider("anthropic-proxy", {
    name: "Anthropic Proxy",
    baseUrl: "https://models.assistant.legogroup.io/anthropic",
    apiKey: "managed-by-extension",
    api: "anthropic-proxy-api",
    models: [
      {
        id: "anthropic.claude-opus-4-6-v1",
        name: "Opus 4.6",
        reasoning: true,
        input: ["text", "image"],
        cost: { input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75 },
        contextWindow: 200000,
        maxTokens: 128000,
      },
      {
        id: "anthropic.claude-sonnet-4-6",
        name: "Sonnet 4.6",
        reasoning: true,
        input: ["text", "image"],
        cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
        contextWindow: 200000,
        maxTokens: 128000,
      },
      {
        id: "anthropic.claude-haiku-4-5-20251001-v1:0",
        name: "Haiku 4.5",
        reasoning: false,
        input: ["text", "image"],
        cost: { input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1 },
        contextWindow: 200000,
        maxTokens: 64000,
      },
    ],
    streamSimple: streamAnthropicProxy,
  });
}
