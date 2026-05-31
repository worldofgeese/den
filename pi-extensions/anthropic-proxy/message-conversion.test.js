import assert from "node:assert/strict";
import test from "node:test";

import {
  convertMessages,
  convertToolResultContent,
  sanitizeSurrogates,
  sanitizeToolId,
} from "./message-conversion.js";

test("sanitizes lone surrogate code units", () => {
  assert.equal(sanitizeSurrogates("ok\uD800bad"), "ok�bad");
});

test("sanitizes Anthropic tool IDs", () => {
  assert.equal(sanitizeToolId("toolu_123:bad.id"), "toolu_123_bad_id");
});

test("drops orphaned assistant tool calls left by aborted turns", () => {
  const messages = convertMessages([
    { role: "user", content: [{ type: "text", text: "call tool" }] },
    { role: "assistant", content: [{ type: "toolCall", id: "orphan:1", name: "bash", arguments: { cmd: "x" } }] },
  ]);

  assert.deepEqual(messages, [
    { role: "user", content: [{ type: "text", text: "call tool" }] },
    { role: "assistant", content: [{ type: "text", text: "..." }] },
  ]);
});

test("keeps matched tool_use/tool_result pairs and sanitizes both IDs consistently", () => {
  const messages = convertMessages([
    { role: "user", content: "use tool" },
    { role: "assistant", content: [{ type: "toolCall", id: "call:1", name: "lookup", arguments: { q: "x" } }] },
    { role: "toolResult", toolCallId: "call:1", content: [{ type: "text", text: "result" }], isError: false },
  ]);

  assert.deepEqual(messages, [
    { role: "user", content: "use tool" },
    { role: "assistant", content: [{ type: "tool_use", id: "call_1", name: "lookup", input: { q: "x" } }] },
    { role: "user", content: [{ type: "tool_result", tool_use_id: "call_1", content: "result", is_error: false }] },
  ]);
});

test("merges adjacent same-role turns created by compaction/custom messages", () => {
  const messages = convertMessages([
    { role: "user", content: "summary" },
    { role: "user", content: [{ type: "text", text: "follow-up" }] },
    { role: "assistant", content: [{ type: "text", text: "first" }] },
    { role: "assistant", content: [{ type: "text", text: "second" }] },
  ]);

  assert.deepEqual(messages, [
    { role: "user", content: [{ type: "text", text: "summary" }, { type: "text", text: "follow-up" }] },
    { role: "assistant", content: [{ type: "text", text: "first" }, { type: "text", text: "second" }] },
  ]);
});

test("ignores unknown user block shapes instead of converting them to bogus images", () => {
  const messages = convertMessages([
    { role: "user", content: [{ type: "text", text: "hello" }, { type: "file", path: "/tmp/x" }] },
  ]);

  assert.deepEqual(messages, [
    { role: "user", content: [{ type: "text", text: "hello" }] },
  ]);
});

test("returns safe empty list for missing or invalid message arrays", () => {
  assert.deepEqual(convertMessages(undefined), []);
  assert.deepEqual(convertMessages({ nope: true }), []);
});

test("converts text-only tool results to Anthropic string content", () => {
  assert.equal(convertToolResultContent([{ type: "text", text: "a" }, { text: "b" }]), "a\nb");
});

test("preserves image tool results as content blocks", () => {
  assert.deepEqual(
    convertToolResultContent([{ type: "text", text: "look" }, { type: "image", mimeType: "image/png", data: "abc" }]),
    [
      { type: "text", text: "look" },
      { type: "image", source: { type: "base64", media_type: "image/png", data: "abc" } },
    ]
  );
});

// ── Gap coverage ────────────────────────────────────────────────────────────

// Gap 1: sanitizeToolId falsy/empty input fallback
test("sanitizeToolId returns stable tool_ prefix for falsy input", () => {
  const result = sanitizeToolId("");
  assert.match(result, /^tool_[a-z0-9]+$/);

  const result2 = sanitizeToolId(null);
  assert.match(result2, /^tool_[a-z0-9]+$/);

  const result3 = sanitizeToolId(undefined);
  assert.match(result3, /^tool_[a-z0-9]+$/);
});

// Gap 2: User message image_url content conversion
test("converts user image blocks to base64 source blocks", () => {
  const messages = convertMessages([
    {
      role: "user",
      content: [
        { type: "text", text: "look at this" },
        { type: "image", mimeType: "image/jpeg", data: "base64data" },
      ],
    },
  ]);

  assert.deepEqual(messages, [
    {
      role: "user",
      content: [
        { type: "text", text: "look at this" },
        { type: "image", source: { type: "base64", media_type: "image/jpeg", data: "base64data" } },
      ],
    },
  ]);
});

// Gap 3: Empty/whitespace-only user text content drops the message
test("drops user messages with whitespace-only string content", () => {
  const messages = convertMessages([
    { role: "user", content: "   " },
    { role: "user", content: "\n\t" },
  ]);

  assert.deepEqual(messages, []);
});

// Gap 4: Assistant thinking-block drop
test("filters out assistant thinking blocks", () => {
  const messages = convertMessages([
    { role: "user", content: "think" },
    {
      role: "assistant",
      content: [
        { type: "thinking", thinking: "internal reasoning" },
        { type: "text", text: "answer" },
      ],
    },
  ]);

  assert.deepEqual(messages, [
    { role: "user", content: "think" },
    { role: "assistant", content: [{ type: "text", text: "answer" }] },
  ]);
});

// Gap 5: Assistant empty-text fallback (all blocks stripped → single empty text)
test("emits single ellipsis text block when all assistant blocks are stripped", () => {
  const messages = convertMessages([
    { role: "user", content: "hi" },
    {
      role: "assistant",
      content: [
        { type: "thinking", thinking: "only thinking" },
      ],
    },
  ]);

  assert.deepEqual(messages, [
    { role: "user", content: "hi" },
    { role: "assistant", content: [{ type: "text", text: "..." }] },
  ]);
});

// Gap 6: toolResult with string body (not array)
test("passes string toolResult content through as-is", () => {
  const messages = convertMessages([
    { role: "user", content: "use tool" },
    { role: "assistant", content: [{ type: "toolCall", id: "t1", name: "fn", arguments: {} }] },
    { role: "toolResult", toolCallId: "t1", content: "plain string result" },
  ]);

  const toolResultBlock = messages[2].content[0];
  assert.equal(toolResultBlock.type, "tool_result");
  assert.equal(toolResultBlock.content, "plain string result");
});

// Gap 7: toolResult with null/undefined content
test("toolResult with null content converts to empty string", () => {
  assert.equal(convertToolResultContent(null), "");
  assert.equal(convertToolResultContent(undefined), "");
});

// Gap 8: toolResult with isError: true
test("toolResult propagates is_error flag", () => {
  const messages = convertMessages([
    { role: "user", content: "use tool" },
    { role: "assistant", content: [{ type: "toolCall", id: "e1", name: "risky", arguments: {} }] },
    { role: "toolResult", toolCallId: "e1", content: "boom", isError: true },
  ]);

  const toolResultBlock = messages[2].content[0];
  assert.equal(toolResultBlock.is_error, true);
});

// Gap 9: Missing toolCall.arguments defaults to {}
test("toolCall without arguments defaults input to empty object", () => {
  const messages = convertMessages([
    { role: "user", content: "call" },
    { role: "assistant", content: [{ type: "toolCall", id: "x1", name: "noop" }] },
    { role: "toolResult", toolCallId: "x1", content: "ok" },
  ]);

  const toolUseBlock = messages[1].content[0];
  assert.deepEqual(toolUseBlock.input, {});
});
