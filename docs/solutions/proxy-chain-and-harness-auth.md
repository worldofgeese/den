# Local Proxy Chain & Agentic Harness Authentication

How LLM requests flow from your coding agent to the LEGO Model Proxy Service,
and how to connect any harness to the chain.

## Explanation: The Proxy Chain

Three layers sit between your coding agent and the upstream model vendor (AWS Bedrock):

```
Your Agent (Claude Code, OMP, OpenCode, Codex, …)
    │
    │  ANTHROPIC_BASE_URL=http://127.0.0.1:18788
    ▼
┌─────────────────────────────────────────────────────────────┐
│  local-model-proxy  (host 18788 → 8788)                             │
│                                                             │
│  What it does:                                              │
│  • Transparent HTTP proxy — forwards every header as-is     │
│  • Tees SSE response streams to extract token counts        │
│  • Emits OpenTelemetry spans to Phoenix for cost analysis   │
│  • Does NOT inject or modify auth headers                   │
│                                                             │
│  Key fact: it only strips RFC 7230 hop-by-hop headers       │
│  (Connection, Transfer-Encoding, etc). Authorization,       │
│  x-api-key, and all other headers pass through untouched.   │
└─────────────────────────────────────────────────────────────┘
    │
    │  MPS_BASE_URL=http://headroom:8787
    ▼
┌─────────────────────────────────────────────────────────────┐
│  Headroom  (host 18787 → 8787)                                      │
│                                                             │
│  What it does:                                              │
│  • Context compression — scores messages by value, drops    │
│    low-signal content before forwarding (47–92% savings)    │
│  • CCR (Compress-Cache-Retrieve) — caches originals for     │
│    lossless on-demand retrieval                             │
│  • SmartCrusher — JSON/array-aware compression (70-90%)     │
│  • Code compression — AST-aware via tree-sitter             │
│  • Semantic caching — deduplicates repeated queries         │
│  • Cache alignment — stabilizes prefixes for KV cache hits  │
│                                                             │
│  Auth handling: passes through to upstream unchanged.       │
│  Mode: HEADROOM_DEFAULT_MODE=optimize (full pipeline)       │
└─────────────────────────────────────────────────────────────┘
    │
    │  ANTHROPIC_TARGET_API_URL=https://api.genai.thelegogroup.com/claude
    ▼
┌─────────────────────────────────────────────────────────────┐
│  LEGO Model Proxy Service (MPS)                             │
│                                                             │
│  What it does:                                              │
│  • Routes requests to AWS Bedrock                           │
│  • Handles model access control, rate limiting, billing     │
│  • Exposes Anthropic-compatible endpoints                   │
│                                                             │
│  Endpoints:                                                 │
│    /claude/v1/messages — Claude Code / native Anthropic     │
│    /anthropic/v1/messages — SDK-style (Anthropic Python)    │
│                                                             │
│  Auth: accepts both Authorization: Bearer <key> AND         │
│        x-api-key: <key>                                     │
│        where <key> = <account_id>:<secret> from MPS portal  │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
  AWS Bedrock (actual model inference)
```

### Why three layers?

| Layer | Purpose | Can you skip it? |
|-------|---------|-----------------|
| local-model-proxy | Observability (token cost, traces) | Yes, point directly at Headroom :8787 |
| Headroom | Token compression (saves budget) | Yes, point directly at MPS |
| MPS | Model access & billing | No — this is the gateway to Bedrock |

The full chain gives you maximum token savings AND full cost visibility.
Skipping Headroom loses compression. Skipping local-model-proxy loses Phoenix traces.

## Reference: Authentication

### The MPS API Key

Format: `<account_id>:<secret>` (roughly 375 characters).

Obtain it from [assistant.legogroup.io/developer/models](https://assistant.legogroup.io/developer/models):
1. Create an account (any name)
2. Request access to Claude Sonnet 4.6, Haiku 4.5, and Opus 4.8
3. Copy the API key from your account page

### Auth headers the proxy chain accepts

The `/claude` MPS endpoint accepts **either**:

| Header | Format | Used by |
|--------|--------|---------|
| `Authorization: Bearer <key>` | Standard Bearer token | Claude Code (via ANTHROPIC_AUTH_TOKEN) |
| `x-api-key: <key>` | Anthropic SDK convention | Anthropic Python SDK, some harnesses |

Both work through the full proxy chain (local-model-proxy and Headroom pass them unchanged).

### Environment variable for Claude Code

```bash
export ANTHROPIC_AUTH_TOKEN="<your MPS API key>"
export ANTHROPIC_BASE_URL="http://127.0.0.1:18788"
```

Claude Code reads `ANTHROPIC_AUTH_TOKEN` and sends it as `Authorization: Bearer`.

## How-To: Connect Any Agentic Harness

The proxy chain is harness-agnostic. Any tool that speaks the Anthropic Messages API
can connect by setting its base URL to `http://127.0.0.1:18788` and providing the MPS key.

### Pattern: What every harness needs

1. **Base URL**: `http://127.0.0.1:18788` (or `:18787` to skip telemetry, or MPS directly)
2. **API key**: Your MPS key (`<account_id>:<secret>`)
3. **Model IDs**: Use Bedrock-style IDs with `anthropic.` prefix:
   - `anthropic.claude-sonnet-4-6`
   - `anthropic.claude-opus-4-8`
   - `anthropic.claude-haiku-4-5-20251001-v1:0`

### Claude Code

```bash
export ANTHROPIC_BASE_URL="http://127.0.0.1:18788"
export ANTHROPIC_AUTH_TOKEN="<key>"
export ANTHROPIC_DEFAULT_SONNET_MODEL="anthropic.claude-sonnet-4-6"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="anthropic.claude-haiku-4-5-20251001-v1:0"
export ANTHROPIC_DEFAULT_OPUS_MODEL="anthropic.claude-opus-4-8"
claude
```

### OpenCode

In `~/.config/opencode/opencode.json`:

```json
{
  "enabled_providers": ["lego-anthropic"],
  "provider": {
    "lego-anthropic": {
      "npm": "@ai-sdk/anthropic",
      "name": "LEGO Anthropic",
      "options": {
        "baseURL": "http://127.0.0.1:18788/v1",
        "apiKey": "<key>",
        "headers": { "api-key": "<key>" }
      },
      "models": {
        "sonnet": { "id": "anthropic.claude-sonnet-4-6", "name": "Sonnet 4.6" },
        "opus":   { "id": "anthropic.claude-opus-4-8", "name": "Opus 4.8" },
        "haiku":  { "id": "anthropic.claude-haiku-4-5-20251001-v1:0", "name": "Haiku 4.5" }
      }
    }
  }
}
```

### OMP (Oh My Pi) / Pi

OMP and Pi share the same config system. In `~/.omp/agent/models.yml`:

```yaml
providers:
  lego:
    api: anthropic-messages
    baseUrl: "http://127.0.0.1:18788"
    apiKey: "!security find-generic-password -ws lego-mps"
    models:
      - id: anthropic.claude-sonnet-4-6
        name: Claude Sonnet 4.6
      - id: anthropic.claude-opus-4-8
        name: Claude Opus 4.8
      - id: anthropic.claude-haiku-4-5-20251001-v1:0
        name: Claude Haiku 4.5
```

Store the key in macOS Keychain:
```bash
security add-generic-password -a "$USER" -s 'lego-mps' -w "<your MPS API key>"
```

**Caveat**: OMP has a bug where `apiKey: ENV_VAR_NAME` resolves the env var in
non-interactive (`-p`) mode but sends the literal string in interactive mode.
The `!command` prefix forces shell execution which works in both modes.
Use `!security find-generic-password -ws lego-mps` (Keychain) or `!cat <file>`.

#### Pi native (without local proxy chain)

Pi can also connect directly to MPS without the local proxy chain.
In `models.json` (Pi's native config format):

```json
{
  "providers": {
    "lego-mps": {
      "name": "LEGO MPS",
      "baseUrl": "https://models.assistant.legogroup.io/openai",
      "apiKey": "!security find-generic-password -ws lego-mps",
      "api": "openai-responses",
      "headers": {
        "api-key": "!security find-generic-password -ws lego-mps",
        "x-api-key": "!security find-generic-password -ws lego-mps"
      },
      "models": [
        {
          "id": "anthropic.claude-opus-4-8",
          "name": "Claude Opus 4.8",
          "api": "anthropic-messages",
          "baseUrl": "https://models.assistant.legogroup.io/anthropic"
        },
        {
          "id": "anthropic.claude-sonnet-4-6",
          "name": "Claude Sonnet 4.6",
          "api": "anthropic-messages",
          "baseUrl": "https://models.assistant.legogroup.io/anthropic"
        },
        {
          "id": "anthropic.claude-haiku-4-5-20251001-v1:0",
          "name": "Claude Haiku 4.5",
          "api": "anthropic-messages",
          "baseUrl": "https://models.assistant.legogroup.io/anthropic",
          "compat": { "supportsEagerToolInputStreaming": false }
        }
      ]
    }
  }
}
```

This bypasses the local proxy chain (no telemetry, no compression) but works
without Docker containers running. The `anthropic-messages` API type with per-model
`baseUrl` overrides lets Anthropic models use the `/anthropic` endpoint while
the provider-level `baseUrl` points at `/openai` for GPT models.

#### Proxy chain vs direct: when to use which

| Approach | Telemetry | Compression | Requires Docker | Use when |
|----------|-----------|-------------|-----------------|----------|
| Through proxy chain (`:18788`) | Yes (Phoenix) | Yes (Headroom) | Yes | Daily work — maximises budget |
| Direct to MPS | No | No | No | Quick test, containers down, travel |

### Anthropic Python SDK

```python
from anthropic import Anthropic

client = Anthropic(
    api_key="<key>",
    base_url="http://127.0.0.1:18788",
    default_headers={"api-key": "<key>"}
)
```

### Generic (curl)

```bash
curl -X POST http://127.0.0.1:18788/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ANTHROPIC_AUTH_TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"anthropic.claude-sonnet-4-6","max_tokens":100,"messages":[{"role":"user","content":"hi"}]}'
```

## Reference: Available Models

| Model ID | Name | Context | Max Output |
|----------|------|---------|-----------|
| `anthropic.claude-opus-4-8` | Claude Opus 4.8 | 200K | 64K |
| `anthropic.claude-sonnet-4-6` | Claude Sonnet 4.6 | 200K | 64K |
| `anthropic.claude-haiku-4-5-20251001-v1:0` | Claude Haiku 4.5 | 200K | 64K |

Check [MPS Swagger UI](https://models.assistant.legogroup.io/docs) for the current list.
Request access via [assistant.legogroup.io/developer/models](https://assistant.legogroup.io/developer/models).

## Explanation: Pi Extension vs Native Config

Pi has a community extension (`anthropic-proxy`) and a native `models.json` approach.
The choice depends on whether you route through the local proxy chain or go direct.

| Approach | Through proxy chain? | Thinking works? | Prompt caching? | Setup |
|----------|---------------------|-----------------|-----------------|-------|
| `anthropic-proxy` extension | Yes (:18788) | Yes (custom SSE parser) | Yes (injects `cache_control`) | Extension install |
| Native `models.json` (Jonas's) | No (direct to MPS) | Unverified | No | Config only |
| OMP via `models.yml` | Yes (:18788) | Yes | OMP-managed | Config only |

### Why the extension is required through the proxy chain

**Verified**: Pi's native `anthropic-messages` type sends auth via `x-api-key` header.
Our proxy chain's final hop (MPS `/claude` endpoint) rejects `x-api-key` and only
accepts `Authorization: Bearer`. The native transport has no config option to change
this — `auth: oauth` and `authHeader: true` both trigger interactive login flows that
block non-interactively.

The extension sends auth via the `api-key` header which MPS accepts at the `/anthropic`
endpoint, and also solves:
- SSE stream parsing for thinking blocks (Bedrock backend returns non-standard SSE)
- Prompt caching via `cache_control: { type: 'ephemeral' }` injection
- Auto-compact warnings at 80% context

### Jonas's native approach (no proxy chain)

Jonas's config works because it points **directly at MPS** (`models.assistant.legogroup.io/anthropic`),
bypassing the local proxy chain entirely. At that endpoint, `x-api-key` is accepted.
The tradeoff: no Phoenix telemetry, no Headroom compression.

```json
{
  "providers": {
    "lego-mps": {
      "name": "LEGO MPS",
      "baseUrl": "https://models.assistant.legogroup.io/openai",
      "apiKey": "!security find-generic-password -ws lego-mps",
      "api": "openai-responses",
      "headers": {
        "api-key": "!security find-generic-password -ws lego-mps",
        "x-api-key": "!security find-generic-password -ws lego-mps"
      },
      "models": [
        {
          "id": "anthropic.claude-sonnet-4-6",
          "name": "Claude Sonnet 4.6",
          "api": "anthropic-messages",
          "baseUrl": "https://models.assistant.legogroup.io/anthropic"
        }
      ]
    }
  }
}
```

### Summary: when to use which

| Your goal | Use |
|-----------|-----|
| Pi + telemetry + compression (full stack) | `anthropic-proxy` extension through `:18788` |
| Pi + simplest setup (no Docker needed) | Native `models.json` direct to MPS |
| OMP + telemetry + compression | `models.yml` with `!security` apiKey through `:18788` |

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `401 Not authenticated` | Missing or empty auth header | Verify key is set and non-empty |
| `400 Malformed Authorization header` | Either the auth value is the literal env var name (not resolved), **or** the request hit the wrong stack on a colliding port (see below) | Use `!cat <file>` / `!security …` so the key resolves; confirm the base URL points at the Apple-container host port (`127.0.0.1:18788`), not a colliding runtime |
| `406 Not found any available model` | Model ID missing `anthropic.` prefix | Use full Bedrock-style ID |
| Connection refused on :18788 | Proxy containers not running | `container ls` (Apple `container` CLI) — restart the launchd agents if headroom / phoenix / local-model-proxy are missing |
| Intermittent `400` from a working config | **Host-port collision**: another runtime (e.g. a Podman `ai-model-gateway` stack) bound the same port. `localhost` resolves IPv6-first and can hit the wrong stack | The Apple-container chain is pinned to distinct host ports (18788 / 18787 / 16006) and OMP uses `127.0.0.1` (IPv4) to avoid ambiguity. Verify with `lsof -nP -iTCP:18788 -sTCP:LISTEN` |
| 200 but slow | Headroom compression overhead on first request per session | Normal; subsequent requests are faster |

## Reference: Observability

With the full chain running:

- **Phoenix UI**: http://localhost:16006 — per-request token counts, cost, session grouping
- **Headroom stats**: http://localhost:18787/stats — compression savings
- **RTK**: `rtk gain` — CLI output compression savings (separate from proxy chain)
