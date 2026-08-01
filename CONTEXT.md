# CONTEXT

Ubiquitous language for this repo. If a word here means something specific,
use it in that sense in code, comments, commit messages, and beads — and do
not substitute a near-synonym.

This file is grown lazily: a term lands here when a change introduces it.

## Structure

| term | means |
|---|---|
| **aspect** | `den.aspects.<name>`, with `.nixos` / `.darwin` / `.homeManager` sub-attributes. The unit of composition. |
| **host** | `den.hosts.<system>.<hostname>` — a machine whose system *and* home are managed here. |
| **home** | `den.homes.<system>.<user>` — standalone Home Manager, no system management. mahakala is a home, not a host. |
| **battery** | `den.batteries.*`, e.g. `define-user`, `primary-user`. |
| **substrate** | NixOS, nix-darwin, Guix System + Guix Home, or nix-on-droid. |
| **entity** | One named machine in the fleet: `mahakala`, `M-02877`, `paphos`, `oracle`, `pixel-fold`. Facts that differ per machine are keyed by entity. |

Design vocabulary (module, interface, depth, seam, adapter, leverage,
locality, the deletion test) comes from the `codebase-design` skill and is used
in that sense in beads under the `architecture` label.

## The model gateway

Owner of every fact below: **`gateway.json`** at the repo root, read by
`modules/gateway.nix` on the Nix side and directly by Guile in
`guix/home-configuration.scm`. See
`docs/adr/0001-gateway-facts-cross-the-guix-seam-as-json.md`.

| term | means |
|---|---|
| **gateway** | The LEGO AI Model Gateway at `api.genai.thelegogroup.com` — the only route to a model. Not a proxy we run. Exposes `/claude` (Claude Code / native Anthropic shape) and `/anthropic` (SDK shape). |
| **headroom** | A token-efficiency proxy we run locally, in front of the gateway. Compresses and freezes prior turns. Container-internal port is always 8787. |
| **proxy chain** | headroom → local-model-proxy → phoenix, wired together on the `proxy-chain` container network. **M-02877 only.** mahakala runs headroom alone. |
| **local-model-proxy** | Transparent proxy that tees SSE streams for token counting and emits OpenTelemetry spans. Adds no auth. |
| **phoenix** | Arize Phoenix, the OpenTelemetry sink the chain reports to. |
| **published port** | The host port an entity exposes a container-internal port on. Keyed by entity in `gateway.json`, because 8787 is internal-only on M-02877 (published as 18787) but is also the host port on mahakala. |
| **keyRef** | How a consumer obtains the gateway key: a *command string* that prints it, never a value. Resolved when an agent process starts, so the key never enters the Nix store or the tree. |
| **tier** | A pi agent model class (`orchestrator`, `creative`, `execution`). Tier *routing* is a separate concern from gateway *addressing*, and has its own owner — see "Tier routing" below. |

One key for every consumer, deliberately: per-harness virtual keys were
considered and rejected on 2026-08-01 (`home-manager-0pr.2`). The gateway
exposes exactly one `keyRef`; do not re-split it without asking.

`anthropic-proxy` is the *provider name* pi uses in `models.json`. It is a
string only — the pi extension of that name was deleted in `d45ddd8`.

## Tier routing

Owner: **`modules/pi-tiers.nix`**. Addressing says how to reach a model;
routing says which model an agent tier gets. They are deliberately separate,
which is why model ids are not in `gateway.json`
(`docs/adr/0001-gateway-facts-cross-the-guix-seam-as-json.md`).

| term | means |
|---|---|
| **tier table** | One profile's `pi.tiers.tiers`: tier name → `model`, `thinking`, and optionally `fallbackModels`. A profile contributes only this. There is no default, so a machine that opts into `den.aspects.pi` without a table fails at eval rather than shipping an empty `tier-defs.json`. |
| **catalogue** | What the gateway serves: the three model ids plus the metadata pi needs for context budgeting. Lives in `modules/pi-tiers.nix` and reaches consumers as the `piTiers` module argument. |
| **slot** | Claude Code's name for a model's role (`opus`, `sonnet`, `haiku`), as opposed to a tier, which is pi's. The catalogue is keyed by slot so `agent-shell` can address a model by role while pi addresses the same model by id. |

The two profiles' tables live with their profiles — `modules/worldofgeese.nix`
and `modules/M-02877/dktaohan.nix`. mahakala's models are provider-native
(`cursor/…`, `openai-codex/…`, `opencode-go/…`) and do **not** go through the
gateway; only M-02877's pi, plus `agent-shell` and Caveman Code on mahakala,
do.

Agent frontmatter is patched at **build** time. It used to be patched during
`home.activation` by an embedded Node script, which ran on both profiles and
overwrote the work profile's build-time patch — so a second, build-time patcher
in `dktaohan.nix` was dead weight. Both are gone. Consequence worth knowing:
the patch moves `thinking:` *above* `fallbackModels:` relative to the source
file in `pi-extensions/agent-overrides/`, because it re-inserts `model:` and
`thinking:` directly after `description:`. That ordering is load-bearing only
in the sense that reproducing it is what made the change invisible on disk.

`~/.cave/agent` (Caveman Code, a pi fork and the primary harness on mahakala)
is **not managed** and holds its own copy of the catalogue — `home-manager-l23`
and `home-manager-8vh`.

## Deploy ordering

On a full `just deploy-mahakala`, Guix Home is reconfigured **before** Home
Manager switches (`Justfile:11-17`), so Home Manager silently wins any
contested file. Anything Guix Home must read has to be present in the tree
rather than generated by Home Manager.
