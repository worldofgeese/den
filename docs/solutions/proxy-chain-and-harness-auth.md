# Local Proxy Chain & Agentic Harness Authentication

How LLM requests flow from a coding agent to the LEGO AI Model Gateway, and how
to connect a harness to the chain.

> **Every address, port, image, and mode named in this document is owned by
> `gateway.json`.** Do not copy a value out of here into a module — read it from
> `modules/gateway.nix` (Nix) or `gateway-ref` (Guile). See
> `docs/adr/0001-gateway-facts-cross-the-guix-seam-as-json.md` and `CONTEXT.md`.

## Explanation: what actually runs where

The chain is **not** the same on both machines, and that is deliberate.

### M-02877 (darwin) — the full chain

```
Claude Code
    │  ANTHROPIC_BASE_URL=http://127.0.0.1:18788
    ▼
┌──────────────────────────────────────────────────────────┐
│  local-model-proxy   (host 18788 → container 8788)       │
│  • forwards every header as-is; adds no auth             │
│  • tees SSE streams to extract token counts              │
│  • emits OpenTelemetry spans to Phoenix                  │
│  • strips only RFC 7230 hop-by-hop headers               │
└──────────────────────────────────────────────────────────┘
    │  MPS_BASE_URL=http://<proxy-chain gateway IP>:18787
    │  (Apple's container tool has no inter-container DNS and
    │   reassigns container IPs on restart, so headroom is
    │   reached through the network gateway's published host
    │   port, which outlives individual containers)
    ▼
┌──────────────────────────────────────────────────────────┐
│  headroom            (host 18787 → container 8787)       │
│  • compresses context; caches originals for retrieval    │
│  • HEADROOM_MODE=cache — freezes prior turns so the      │
│    gateway's prefix cache keeps hitting. `token` would   │
│    compress harder but rewrites history, busting the     │
│    cache and costing more on a prefix-caching provider.  │
│  • passes auth through unchanged                         │
└──────────────────────────────────────────────────────────┘
    │  ANTHROPIC_TARGET_API_URL=https://api.genai.thelegogroup.com/claude
    ▼
  LEGO AI Model Gateway ──► upstream model vendor
```

Phoenix runs alongside on host `16006` → container `6006`.

**pi does not use this chain.** pi talks straight to
`https://api.genai.thelegogroup.com/anthropic` through the built-in
`anthropic-messages` API declared in `models.json`
(`modules/M-02877/dktaohan.nix`). The chain is for Claude Code.

### mahakala (Guix System + Guix Home) — headroom only

headroom runs as a Guix Home OCI service under rootless podman
(`guix/home-configuration.scm`), published on `127.0.0.1:8787`. There is **no
local-model-proxy and no Phoenix** on mahakala, so there is no telemetry there.
Its consumer is agent-shell inside Doom Emacs
(`modules/doom.d/modules/tools/agent-shell/config.el`), which points
`ANTHROPIC_BASE_URL` at `http://127.0.0.1:8787`.

`HEADROOM_MODE` was absent from the Guix side until `home-manager-0pr.2`, so
mahakala silently ran headroom's built-in default mode. It is now set from
`gateway.json` on both substrates.

### Why the layers, and what you lose by skipping one

| layer | buys you | skippable? |
|---|---|---|
| local-model-proxy | token counts and Phoenix traces | yes — point at headroom directly, lose telemetry |
| headroom | context compression and prefix-cache stability | yes — point at the gateway directly, lose savings |
| gateway | model access, quota, billing | no |

## Reference: authentication

One secret for every consumer: **`LEGO_GATEWAY_API_KEY`**, a gateway virtual key
(`vk_…`), declared in `secretspec.toml` and stored per host by
`secretspec set`. Per-harness keys were considered and rejected
(`home-manager-0pr.2`); see `CONTEXT.md`.

The key is never a value in this repo — always a **command** that prints it:

| consumer | how it resolves the key |
|---|---|
| pi | `apiKey` in `models.json` is `!secretspec get -f …/secretspec.toml LEGO_GATEWAY_API_KEY`; `!` is pi's marker for "run this and use the output" |
| agent-shell | runs the same command at agent-process start, via advice on `agent-shell-anthropic-make-claude-client`; an empty or failing lookup raises a `user-error` naming the command instead of sending a blank header |
| Claude Code | reads its own `~/.claude/settings.json` `env` block, which is **outside this repo** |

Both `Authorization: Bearer <key>` and `x-api-key: <key>` reach the gateway
unchanged through the chain.

### Why `ANTHROPIC_*` is not set in launchd for Claude Code

`modules/M-02877/darwin.nix` deliberately sets no `ANTHROPIC_*` variables on the
`gascity-supervisor` agent. Claude Code's `~/.claude/settings.json` `env` block
overrides the inherited environment, so anything set in launchd is silently
ignored. Gateway URL, token, and model IDs live there.

## Reference: model IDs

Model IDs are **not** owned by `gateway.json` — they are routing, not
addressing. Their owner is the catalogue in `modules/pi-tiers.nix`, which
reaches consumers as the `piTiers` module argument (`home-manager-0pr.3`).

The two Nix consumers used to disagree, and the elisp was the stale one:

| consumer | IDs before `0pr.3` |
|---|---|
| pi (`modules/M-02877/dktaohan.nix`) | `eu.anthropic.claude-opus-5`, `eu.anthropic.claude-sonnet-5`, `eu.anthropic.claude-haiku-4-5-20251001-v1:0` |
| agent-shell (`config.el`) | `anthropic.claude-opus-4-6-v1`, `anthropic.claude-sonnet-4-6`, `anthropic.claude-haiku-4-5-20251001-v1:0` |

Both now derive from the catalogue: `config.el` carries
`@GATEWAY_{OPUS,SONNET,HAIKU}_MODEL@` placeholders that `modules/doom-emacs.nix`
substitutes with `--replace-fail`, so a renamed or dropped id is a build error.
The elisp's IDs were confirmed stale against `~/.cave/agent/models.json` on
mahakala, which reaches the *same* endpoint (`http://127.0.0.1:8787`) with the
`eu.anthropic.…-5` ids.

A third copy of the catalogue still exists in that hand-written
`~/.cave/agent/models.json` — see `home-manager-l23` (it also embeds a literal
key) and `home-manager-8vh` (its `contextWindow`/`maxTokens` disagree).

`anthropic-proxy` is pi's *provider name* in `models.json` and nothing more. The
pi extension of that name was deleted in `d45ddd8`; there is no
`pi-extensions/anthropic-proxy` and no provider extension is needed, because the
gateway is a faithful Anthropic Messages passthrough.

## How-To: connect another harness

1. **Base URL** — `http://127.0.0.1:18788` on M-02877 for the full chain,
   `http://127.0.0.1:18787` to skip telemetry, or
   `https://api.genai.thelegogroup.com/anthropic` to go direct. On mahakala,
   `http://127.0.0.1:8787`.
2. **Key** — resolve `LEGO_GATEWAY_API_KEY` through `secretspec get`, as a
   command, not a pasted value.
3. **Model IDs** — copy from the table above for the harness you are matching.

Example, Anthropic Python SDK against the full chain on M-02877:

```python
import os, subprocess
from anthropic import Anthropic

key = subprocess.check_output(
    ["secretspec", "get", "-f",
     os.path.expanduser("~/.config/home-manager/secretspec.toml"),
     "LEGO_GATEWAY_API_KEY"], text=True).strip()

client = Anthropic(api_key=key, base_url="http://127.0.0.1:18788")
```

## How-To: verify a Guix-side change without mahakala

`just check` does not evaluate the Guix files at all
(`home-manager-0pr.4`), and darwin has no `guile` or `guix`. Run real Guix in a
container instead — this is how the `gateway.json` seam was validated:

```sh
container image pull registry.gitlab.com/debdistutils/guix/container:latest

# Render the actual OCI record out of home-configuration.scm and inspect it.
# Feed the script and gateway.json in on stdin; HOME must be set for guix.
container run --rm -i --platform linux/arm64 \
  --entrypoint /bin/sh \
  registry.gitlab.com/debdistutils/guix/container:latest -s <<'EOF'
mkdir -p /root/.config/home-manager
export HOME=/root
# ... copy gateway.json to /root/.config/home-manager/ and a probe .scm in,
# then:
guix repl -- /root/probe.scm
EOF
```

A probe that imports `(gnu services containers)`, constructs the
`oci-container-configuration`, and calls `oci-container-configuration->options`
prints the exact podman arguments Guix Home will use. Diffing that output
against the pre-change file is a real before/after check.

Two things this caught that review would not have:

- Guix's guile-json decodes JSON objects to **alists**, not hash tables, so
  `hash-ref` fails. `gateway-object-ref` accepts either.
- `(use-modules (json))` does resolve under Guix's own Guile, which is what made
  the whole approach viable.

Building a full `guix home` derivation additionally needs `guix-daemon` running
with build users — see the container project's README for that setup. It is not
required just to check field types and rendered options.

## Troubleshooting

| symptom | cause | fix |
|---|---|---|
| `401 Not authenticated` | missing or empty auth header | run the `secretspec get` command by hand; confirm it prints a `vk_…` value |
| `400 Malformed Authorization header` | the auth value is a literal variable name rather than a resolved key, **or** the request hit a colliding port | ensure the key comes from a `!command` / `call-process`; confirm the base URL is the Apple-container host port, not another runtime |
| `406 Not found any available model` | model ID not in the gateway's list | use an ID from the model table above |
| connection refused on `:18788` | chain containers not running | `container ls`; restart the launchd agents if headroom / phoenix / local-model-proxy are missing |
| intermittent `400` from a working config | **host-port collision** — another runtime bound the same port, and `localhost` resolves IPv6-first | the chain is pinned to distinct host ports and consumers use `127.0.0.1`; verify with `lsof -nP -iTCP:18788 -sTCP:LISTEN` |
| `502` on every request, all containers `running` | headroom restarted onto a new container IP and local-model-proxy holds the old one | handled in `darwin.nix` by targeting the network gateway; for a hand-run container, restart local-model-proxy **after** headroom |
| requests hang for minutes | headroom's upstream connection pool wedged (seen after ~2 days uptime, sockets in `CLOSE_WAIT`); `/livez` still returns 200 | compare `/livez` (fast) against `/readyz` (hangs), then `container stop headroom` and let launchd `KeepAlive` relaunch it |
| mahakala costs look different from M-02877 | before `home-manager-0pr.2`, `HEADROOM_MODE` was unset there | fixed; takes effect on the next `guix home reconfigure` |
| 200 but slow on the first request of a session | headroom compression overhead | normal |

`/livez` is pure process liveness. `/readyz` and `/health` also probe upstream
and will hang when the pool wedges, which is why startup gating uses `/livez`.

## Reference: observability

Full chain on M-02877 only:

- **Phoenix UI** — <http://localhost:16006>, per-request token counts and cost
- **headroom stats** — <http://localhost:18787/stats>, compression savings
- **RTK** — `rtk gain`, CLI output compression, unrelated to the chain

## Related beads

- `home-manager-0pr.2` — gave the gateway one owner (this document's premise)
- `home-manager-0pr.3` — one tier-routing module; owns the model-ID catalogue
- `home-manager-l23` — `~/.cave/agent` is unmanaged and holds a literal key
- `home-manager-8vh` — catalogue metadata disagrees between the two copies
- `home-manager-0pr.4` — `just check` does not cover Guix, images, or tofu
- `home-manager-zdo` — `/v1/*` is unauthenticated on a non-loopback bind;
  `HEADROOM_PROXY_TOKEN` unset. M-02877 publishes headroom on all interfaces,
  which is a one-value change in `gateway.json`
