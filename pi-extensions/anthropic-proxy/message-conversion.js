// Pure Anthropic Messages API conversion helpers.
// Kept dependency-free so edge cases can be unit tested outside Pi runtime.

export function sanitizeSurrogates(text) {
  return String(text ?? "").replace(/[\uD800-\uDFFF]/g, "\uFFFD");
}

/**
 * Anthropic/Bedrock require tool_use IDs to match ^[a-zA-Z0-9_-]+$.
 */
export function sanitizeToolId(id) {
  if (!id) return "tool_" + Date.now().toString(36);
  return String(id).replace(/[^a-zA-Z0-9_-]/g, "_");
}

function textBlock(text) {
  return { type: "text", text: sanitizeSurrogates(text) };
}

function imageBlock(item) {
  if (!item?.mimeType || !item?.data) return undefined;
  return { type: "image", source: { type: "base64", media_type: item.mimeType, data: item.data } };
}

function normalizeUserContent(content) {
  if (typeof content === "string") {
    return content.trim() ? sanitizeSurrogates(content) : undefined;
  }

  if (!Array.isArray(content)) return undefined;

  const blocks = [];
  for (const item of content) {
    if (item?.type === "text") {
      blocks.push(textBlock(item.text || ""));
    } else if (item?.type === "image") {
      const block = imageBlock(item);
      if (block) blocks.push(block);
    }
  }
  return blocks.length > 0 ? blocks : undefined;
}

export function convertToolResultContent(content) {
  if (typeof content === "string") return sanitizeSurrogates(content);
  if (!Array.isArray(content)) return "";

  const hasImages = content.some((item) => item?.type === "image");
  if (!hasImages) {
    return sanitizeSurrogates(
      content
        .filter((item) => item?.text != null)
        .map((item) => item.text)
        .join("\n")
    );
  }

  const blocks = [];
  for (const item of content) {
    if (item?.type === "text") {
      blocks.push(textBlock(item.text || ""));
    } else if (item?.type === "image") {
      const block = imageBlock(item);
      if (block) blocks.push(block);
    }
  }
  return blocks;
}

function asBlockArray(content) {
  return typeof content === "string" ? [textBlock(content)] : content;
}

function appendAnthropicMessage(messages, message) {
  if (!message?.role || message.content === undefined) return;
  const last = messages[messages.length - 1];

  // Anthropic rejects adjacent same-role turns in some Bedrock paths. Pi can
  // produce them after compaction, custom messages, or several tool results.
  // Merge same-role neighbors while preserving original block order.
  if (last?.role === message.role) {
    const merged = [...asBlockArray(last.content), ...asBlockArray(message.content)];
    last.content = merged;
    return;
  }

  messages.push(message);
}

export function convertMessages(messages = []) {
  const inputMessages = Array.isArray(messages) ? messages : [];

  // Collect original tool_result IDs so aborted responses do not leave orphaned
  // tool_use blocks in history. Compare before sanitizing; sanitize only at API edge.
  const toolResultIds = new Set();
  for (const msg of inputMessages) {
    if (msg?.role === "toolResult" && msg.toolCallId) {
      toolResultIds.add(msg.toolCallId);
    }
  }

  const params = [];
  for (const msg of inputMessages) {
    if (!msg || typeof msg !== "object") continue;

    if (msg.role === "user") {
      const content = normalizeUserContent(msg.content);
      if (content !== undefined) appendAnthropicMessage(params, { role: "user", content });
      continue;
    }

    if (msg.role === "assistant") {
      const blocks = [];
      const content = Array.isArray(msg.content) ? msg.content : [];
      for (const block of content) {
        if (block?.type === "text" && block.text?.trim()) {
          blocks.push(textBlock(block.text));
        } else if (block?.type === "thinking") {
          // Historical thinking signatures are model-version-specific and often
          // invalid after session storage, compaction, or surrogate cleanup.
          // Drop them rather than sending invalid signed thinking blocks.
        } else if (block?.type === "toolCall" && toolResultIds.has(block.id)) {
          blocks.push({
            type: "tool_use",
            id: sanitizeToolId(block.id),
            name: block.name,
            input: block.arguments || {},
          });
        }
      }

      if (blocks.length > 0) {
        appendAnthropicMessage(params, { role: "assistant", content: blocks });
      } else if (content.length > 0) {
        // Preserve alternation when every assistant block was stripped.
        appendAnthropicMessage(params, { role: "assistant", content: [textBlock("...")] });
      }
      continue;
    }

    if (msg.role === "toolResult") {
      appendAnthropicMessage(params, {
        role: "user",
        content: [{
          type: "tool_result",
          tool_use_id: sanitizeToolId(msg.toolCallId),
          content: convertToolResultContent(msg.content),
          is_error: msg.isError === true,
        }],
      });
    }
  }

  return params;
}
