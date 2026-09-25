# Interfaces

## Contract Principles
- Prefer explicit schemas over implicit behavior.
- Every mutating interface defines idempotency semantics.
- Every failure path maps to a typed, documented error code.

## Generated Contract Depth
Generated interface specs should include:
- API/CLI contracts with request/response schemas.
- Read/write ownership for each storage path.
- Idempotency and retry behavior for mutations.
- Typed failure classes and recovery instructions.

## API / RPC Contracts
| Interface | Method | Request Schema | Response Schema | Errors | Idempotency |
|---|---|---|---|---|---|
| `TODO` | `TODO` | `TODO` | `TODO` | `TODO` | `TODO` |

## Event Consumers
| Consumer | Event | Ordering Requirement | Retry Policy | DLQ Policy |
|---|---|---|---|---|
| `TODO` | `TODO` | `TODO` | `TODO` | `TODO` |

## Outbound Dependencies
| Dependency | Purpose | SLA | Timeout | Circuit-Breaker |
|---|---|---|---|---|
| `TODO` | `TODO` | `TODO` | `TODO` | `TODO` |

## Inbound Contracts
- API / RPC entrypoints:
- CLI surfaces:
- Event/webhook consumers:
- Repository-detected surfaces: shell

## Data Ownership
- Source-of-truth tables/collections: `gateway.json` is the single owner of how
  an agent reaches a model -- addresses, published ports, the secret's *name*,
  and (since the agent-provider work) the model catalogue: slot -> id plus the
  `contextWindow` and `maxTokens` ceilings the gateway enforces.
- Cross-boundary read models: two readers, one per substrate, because
  `guix/home-configuration.scm` is Scheme and cannot import Nix (ADR 0001).
  Nix reads it in `modules/gateway.nix` and republishes derived values as the
  `gateway` module argument; Guile reads the same file via guile-json.
- Consistency expectations: consumers are thin adapters and MUST NOT restate a
  fact `gateway.json` already owns. The catalogue moved there precisely because
  it had been duplicated in pi's and Caveman Code's configs and the two copies
  disagreed on both ceilings (`home-manager-8vh`).

## Agent Provider Interface
`modules/agent-providers.nix` adapts one gateway to four CLI harnesses. Shapes
are taken from the gateway's own setup docs, published as React pages in
`LEGO/ai-model-gateway-client` (`src/features/docs/pages/`), not inferred.

| Harness | Config it reads | Provider key | How the credential arrives |
|---|---|---|---|
| omp | `~/.omp/agent/models.yml` (migrates `models.json` on first run) | `lego-claude` | `apiKey: "!<cmd>"` |
| pi | `~/.pi/agent/models.json` | `lego-claude` | `apiKey: "!<cmd>"` |
| Caveman Code | `~/.cave/agent/models.json` | `lego-claude` | `apiKey: "!<cmd>"` |
| Claude Code | none; wrapper-supplied environment | n/a | `ANTHROPIC_AUTH_TOKEN` exported at process start |

The credential is never a value in this repository. It crosses as a *command*
that prints it when an agent process starts, so it reaches neither the store nor
the work tree. The three pi-family harnesses resolve `!command` themselves.
Claude Code has no equivalent marker, so its wrapper runs the lookup and exports
the documented variable -- the same technique `modules/M-02877/dktaohan.nix`
already used for `CHORUS_API_KEY`.

Ownership of these files is deliberately partial. Each harness writes its own
picked default back (`/model`), so a store symlink would make that write fail.
Home Manager seeds a file only when absent and never reverts it, which makes
later drift a deliberate local edit rather than something a switch silently
undoes. The cost is that a stale hand-edited file is *not* corrected by
deploying; `home-manager-l23` was exactly that case and had to be replaced by
hand.

Two asymmetries are load-bearing and easy to reintroduce:
- omp validates its schema strictly and disables *every* custom provider on an
  unknown key, so pi's `forceAdaptiveThinking` / `thinkingLevelMap` must not
  appear in its file. omp's equivalent is `thinking.mode: anthropic-adaptive`.
- Haiku 4.5 must keep `reasoning: false`; a configured thinking level trips
  "adaptive thinking is not supported on this model".

## Error Taxonomy Example (service_or_library)
```ts
export enum ApiErrorCode {
  Validation = "validation_failed",
  UpstreamTimeout = "upstream_timeout",
  Conflict = "conflict"
}
```

## Failure Semantics
| Failure Class | Retry/Backoff | Client Contract | Observability |
|---|---|---|---|
| Validation | No retry | 4xx typed error | warn log + metric |
| Dependency timeout | Exponential backoff | 503 with retryable code | error log + alert |
| Conflict | Conditional retry | 409 with conflict detail | info log + metric |

## Timeout Budget
| Hop | Budget (ms) | Notes |
|---|---|---|
| Client -> Edge/API | 500 | Includes auth + routing |
| API -> Domain | 300 | Includes validation |
| Domain -> Store/Dependency | 200 | Includes retry overhead |

## Interface Versioning
- Version strategy (`v1`, date-based, semver):
- Backward-compatibility guarantees:
- Deprecation window and removal policy:

## CLI and Machine-Readable Contract
| Surface | Invocation/Shape | Reads | Writes | Output Stability | Proof |
|---|---|---|---|---|---|
| Human CLI | `claude` (wrapped) | `gateway.json` via wrapper env | nothing in this repo | vendor-defined | `claude -p` answered through the gateway post-deploy |
| Human CLI | `omp`, `pi`, `caveman` | `~/.<tool>/agent/models.{json,yml}` | same file, on `/model` | vendor-defined | each listed all three models and completed an Opus tool call |
| JSON/automation | `gateway.json` | hand-written facts | never written by Nix | additive; keys prefixed `_` are prose | consumed by `modules/gateway.nix` and `guix/home-configuration.scm` |
| Event/file boundary | secret lookup command | `secretspec.toml` | nothing | exit status + stdout | key confirmed absent from the built closure |

## Beads Tooling Boundary
Beads task state uses the legacy `bd` CLI as the single project workflow
interface. Linux Home Manager profiles receive the Nixpkgs `beads` and `dolt`
packages, with `beads` providing the `bd` command; the Darwin profile resolves
`bd` from Homebrew at `/opt/homebrew/bin` and keeps Dolt under nix-darwin.
Codex, Cursor, and Git hook integrations all invoke `bd` directly. The Rust
`br` CLI and `bv` viewer are not part of the supported package or interface
surface.

## Compatibility Matrix
| Contract | Current Version | Consumers | Additive Changes | Breaking Changes | Migration Trigger |
|---|---|---|---|---|---|
| Request/input | | | | | |
| Response/output | | | | | |
| Persisted data | | | | | |
| Events/artifacts | | | | | |

## Observability Contract
- Correlation/request identity:
- Structured fields required on success:
- Structured fields required on failure:
- Audit events for sensitive mutations:
- Metrics and traces that prove latency, retries, and outcomes:

## Interface Change Review
- [ ] The owner and source of truth are named for every changed field.
- [ ] Retry, idempotency, timeout, and conflict behavior are explicit.
- [ ] Consumers can distinguish validation, authorization, conflict,
  dependency, and internal failures.
- [ ] Backward compatibility or migration instructions are published.

## Doom Emacs Interactive Writing Controls
These Home Manager managed Doom controls are the user-facing interface for
editing and focused writing:

| Control | Default | Behavior | Configuration owner |
|---|---|---|---|
| Evil escape | `jk` | Return from Evil insert state to normal state | `modules/doom.d/config.el` |
| Zen buffer toggle | `SPC t z` | Center the current buffer in an 80-column writing area; toggle again to restore the regular view | Doom `:ui zen` |
| Zen full-screen toggle | `SPC t Z` | Apply the focused layout and full-screen the Emacs frame; toggle again to restore it | Doom `:ui zen` |

The `:ui zen` module bundles Writeroom behavior; users do not install or
configure Olivetti separately for this workflow.

## Secret Store and MCP Operator Interface
| Command or file | Effect | Owner |
|---|---|---|
| `just secretspec-se-setup` | Creates this Mac's post-quantum Secure Enclave key if missing, writes `secretspec.age.recipients` (Secure Enclave key + backup key), and re-encrypts `secretspec.age`; backup key from stdin or the old Keychain item | `Justfile` |
| `pbpaste \| just secretspec-se-setup` | New-Mac recovery from the password-manager backup key | `Justfile` |
| `just secretspec-age-backup` | Copies the backup key from the old Keychain item to the clipboard; cleared after 60 s | `Justfile` |
| `~/.config/secretspec/config.toml` | Defines the `personal` alias for each host; generated, not hand-edited | `modules/shared-devtools.nix` |
| `~/.config/mcp/mcp.json` | Declares the `nixos` MCP server (mcp-nixos) for pi-mcp-adapter, with direct tools | `modules/shared-devtools.nix` |

## Mahakala Maintenance Interface
| Command or setting | Reads | Writes | Scope | Proof |
|---|---|---|---|---|
| `just deploy-mahakala` | Guix channel files, `flake.lock`, and Mahakala configuration | Mahakala Guix System, Guix Home, and Home Manager profiles | Mahakala only | Each profile reports a new active generation |
| `just guix-pull-system` | `guix/channels.scm` below `justfile_directory()` | Root Guix profile | Mahakala system source | `guix describe` reports the pulled revisions |
| `just deploy-mahakala-system` | `guix/system.scm` and `guix-packages/` below `justfile_directory()` | Guix System generation | Mahakala only | `guix system describe` reports the new generation |
| `ath10k_pci.reset_mode=1` | `guix/system.scm` kernel arguments | Linux boot command line | QCA6174 on Mahakala | Built `ath10k_pci` module reports `1` as warm-only reset; runtime proof waits for the next planned boot |

These commands do not force an immediate reboot. The next planned boot verifies the Wi-Fi recovery trial.

## Darwin Deploy Preflight
| Command or file | Effect | Exit |
|---|---|---|
| `scripts/cask-app-preflight.sh` (first step of `just deploy-darwin`) | Moves a Caskroom backup left by a failed upgrade to `~/.Trash` when the live app exists; lists casked apps with non-user-owned files | 0 = proceed; 1 = prints the `osascript ... chown -R` fix and stops the deploy |
| `/etc/homebrew/brew.env` | `HOMEBREW_NO_ENV_HINTS=1`, `HOMEBREW_SERVICES_NO_DOMAIN_WARNING=1` for every brew invocation | n/a |

<!-- decapod:codebase-attestation:start -->

## Codebase Attestation

- Repository signal fingerprint: `ffee50b413844cc1e3e37983172e16ba68d172c404fcc7495b65983cf5027faf`
- Significant implementation surfaces: `.beads/` (1 files), `.github/` (1 files), `README.md/` (1 files), `docs/` (2 files), `terraform/` (1 files)
- Refreshed from the current codebase by `decapod specs.refresh`
<!-- decapod:codebase-attestation:end -->
