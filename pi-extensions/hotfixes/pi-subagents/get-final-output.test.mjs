#!/usr/bin/env node
/**
 * Behavioral check: last non-empty assistant text part wins (Composer multi-text).
 */
import assert from "node:assert/strict";

function getFinalOutputForward(messages) {
	for (let i = messages.length - 1; i >= 0; i--) {
		const msg = messages[i];
		if (msg.role === "assistant") {
			for (const part of msg.content) {
				if (part.type === "text" && part.text.trim().length > 0) return part.text;
			}
		}
	}
	return "";
}

function getFinalOutputBackward(messages) {
	for (let i = messages.length - 1; i >= 0; i--) {
		const msg = messages[i];
		if (msg.role === "assistant") {
			for (let j = msg.content.length - 1; j >= 0; j--) {
				const part = msg.content[j];
				if (part.type === "text" && part.text.trim().length > 0) return part.text;
			}
		}
	}
	return "";
}

const composerStyleAssistant = {
	role: "assistant",
	content: [
		{ type: "text", text: "Working on the fix..." },
		{ type: "thinking", thinking: "planning tool use" },
		{ type: "text", text: "Implemented: patch applied." },
	],
};

const messages = [{ role: "user", content: [{ type: "text", text: "fix it" }] }, composerStyleAssistant];

assert.equal(getFinalOutputForward(messages), "Working on the fix...");
assert.equal(getFinalOutputBackward(messages), "Implemented: patch applied.");

console.log("get-final-output.test.mjs: ok");
