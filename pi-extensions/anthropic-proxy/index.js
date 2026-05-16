/**
 * Anthropic Proxy Provider Extension for Pi
 *
 * Routes Anthropic API calls through a corporate proxy that authenticates
 * via the `api-key` header (not the standard `x-api-key`).
 *
 * The proxy is LiteLLM routing to AWS Bedrock, speaking the Anthropic
 * Messages API format.
 *
 * Usage:
 *   pi --provider anthropic-proxy
 *   pi --provider anthropic-proxy --model "Opus 4.6"
 */

const { execSync } = require("child_process");

// Resolve API key from gopass at load time
function getApiKey() {
  try {
    return execSync("gopass show -o dev/anthropic-proxy-key", {
      encoding: "utf-8",
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (e) {
    throw new Error(
      "Failed to retrieve API key from gopass. Ensure 'dev/anthropic-proxy-key' exists."
    );
  }
}

module.exports = function (pi) {
  const apiKey = getApiKey();
  const baseUrl = "https://models.assistant.legogroup.io/anthropic";

  pi.registerProvider("anthropic-proxy", {
    name: "Anthropic Proxy",
    baseUrl,
    apiKey,
    api: "anthropic-messages",
    headers: {
      "api-key": apiKey,
    },
    models: [
      {
        id: "anthropic.claude-opus-4-6-v1",
        name: "Opus 4.6",
        reasoning: false,
        input: ["text", "image"],
        cost: { input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75 },
        contextWindow: 200000,
        maxTokens: 16384,
      },
      {
        id: "anthropic.claude-sonnet-4-6",
        name: "Sonnet 4.6",
        reasoning: false,
        input: ["text", "image"],
        cost: { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
        contextWindow: 200000,
        maxTokens: 16384,
      },
      {
        id: "anthropic.claude-haiku-4-5-20251001-v1:0",
        name: "Haiku 4.5",
        reasoning: false,
        input: ["text", "image"],
        cost: { input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1 },
        contextWindow: 200000,
        maxTokens: 16384,
      },
    ],
  });
};
