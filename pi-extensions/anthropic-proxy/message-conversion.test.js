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
