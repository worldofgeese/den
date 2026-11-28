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
| OpenClaw Gateway `https://loving-kypris.hound-celsius.ts.net` | Control UI and device pairing for the OpenClaw agent gateway (loving-kypris) | tailnet-only, no public SLA | browser default; websocket reconnect is client-driven | none; the Control UI surfaces "Couldn't connect" and the desktop entry opens a browser without a runtime dependency |

## OpenClaw Client Interface

Mahakala reaches the OpenClaw gateway through exactly one path, and the
Control UI in a browser is the supported client:

```
browser --https--> tailscale serve (:443, tailnet only)
                 --> 127.0.0.1:18790 (published from openclaw-gateway)
                 --> socat in the gateway netns
                 --> 127.0.0.1:18789 (gateway, bind: loopback)
```

- Declared interface: `xdg.dataFile "applications/openclaw-control-ui.desktop"`
  in `modules/workstation.nix` is the only "OpenClaw" launcher. It runs
  `xdg-open https://loving-kypris.hound-celsius.ts.net`.
- Desktop-app config: `~/.config/openclaw-desktop/gateway.json` is rendered by
  `home.activation.installOpenclawDesktopConfig`, which owns
  `.gateway.remote.url = wss://loving-kypris.hound-celsius.ts.net`. The gateway
  token is never declarative; it stays inside that 0600 file and is entered once.
- Auth is unchanged: `gateway.auth.mode = token`, `allowTailscale = false`, and
  browser access additionally requires an approved device pairing
  (`openclaw devices approve <request-id>` on the gateway host).
- The published Linux desktop AppImage is NOT an interface: it cannot create an
  EGL display under `appimage-run`'s bubblewrap on Guix System and the bundled
  WebKit throws `undefined symbol: soup_uri_new`. See home-manager-1j8.
- Failure semantics: an unreachable gateway is a tailnet/ingress fault, not an
  auth fault -- diagnose with `tailscale serve status` on loving-kypris and
  `curl -fsS https://loving-kypris.hound-celsius.ts.net/` from mahakala before
  touching tokens.

## Inbound Contracts
- `decapod validate` selects the Alejandra and ShellCheck executable paths
  for `linux-x86_64` or `macos-aarch64` from the required repository
  profile in `.decapod/config.toml`. Both hosts use the same reviewed
  arguments and workflow coverage. An undeclared platform or a missing
  pinned executable blocks local readiness.
- The Superwhisper installer accepts `--background` and retains the Cloud/Offline confirmation prompt.
  Before confirmation, it explains that Cloud sends audio, transcripts, and required
  context to the selected provider. Superwhisper-hosted Cloud models process content
  in memory without retention; third-party Cloud models follow their providers' terms.
  Offline models run on this device.
  After confirmation it takes an exclusive lock at
  `$XDG_STATE_HOME/den/app-list.lock`, with the standard state-directory fallback.
  Another Superwhisper setup
  or removal exits before changing user state.
  It atomically disables crash reports before startup and saves the backend
  after successful package deployment and CLI configuration. A preference-write
  failure leaves the prior preference unchanged and is reported without claiming
  that crash reports were disabled.
  Cancellation installs nothing and writes no preferences or backend selection.
- If setup fails after confirmation, it stops only a daemon started by this attempt
  and removes only an app entry that this attempt added.
  It restores the previous dictation selection only if the current selection is still
  Superwhisper; a newer choice is preserved. A completed preference update leaves
  crash reports disabled; if that update fails, the prior value remains unchanged
  and the error message says so.
  It preserves any app and daemon that existed before setup.
- The Guix Superwhisper helper accepts `start` or `stop`.
  It uses `SUPERWHISPER_RUNTIME`, or `$XDG_RUNTIME_DIR/superwhisper`, for private locks and the control socket.
  Its startup and shutdown checks each allow ten seconds.
  Its internal `stop-owned` command requires the setup attempt's owner token.
  It records ownership only after `flock` grants the daemon lock and stops the daemon
  only when the runtime owner file matches that token.
  It writes daemon output to `$XDG_STATE_HOME/superwhisper/guix-daemon.log`, with the standard XDG fallback.
  Removal preserves preferences, models, and history.
- Home Manager installs `20-guix-superwhisper` under
  `$XDG_CONFIG_HOME/omarchy/hooks/post-boot.d` (or `~/.config` when unset) only
  when that path is absent, preserving user-owned hooks.
  The hook calls `omarchy-superwhisper-autostart` through the current Home
  Manager profile's Omarchy tree. The helper reads the selected
  backend from `omarchy/defaults/dictation` and invokes the idempotent service
  start only for `superwhisper`. A missing or different backend is a no-op;
  autostart never invokes the dictation command or begins recording.
- The Superwhisper package in `modules/omarchy-apps.json` is
  `nixarchy-apps.superwhisper`, resolved against the extended overlay in
  `modules/omarchy.nix`. The profile therefore provides `bin/superwhisper`.
  Every entry point has `LD_LIBRARY_PATH` extended with the wayland and
  vulkan-loader store directories. `SUPERWHISPER_RUNTIME` defaults to
  `$XDG_RUNTIME_DIR/superwhisper` and `SUPERWHISPER_APP_DIR` defaults to the
  package's app tree; an inherited value of either variable is kept.
  `VK_ICD_FILENAMES` stays unset, so the Vulkan loader reads the Guix ICDs from
  `$XDG_DATA_DIRS`.
- The `omarchy-den-apps` wrapper in `modules/omarchy.nix` uses `DEN_DIR`, then
  `$XDG_STATE_HOME/den/app-source`, then the main checkout.
  The optional marker is a user-managed source-directory symlink.
  This change reads the marker; deployment does not create or update it.
  A marker whose target no longer exists falls back to the main checkout, so a
  removed workspace does not break the app list. An explicit `DEN_DIR` that is
  wrong still fails before changing the app list.
  Ordinary app-list operations acquire the Superwhisper setup lock for their
  complete deployment. Setup and removal pass an internal lock context to their
  app-list calls while the parent retains that lock. The wrapper accepts that
  context only when fd 8 refers to the same `app-list.lock` file; an exported
  flag or unrelated open descriptor cannot bypass locking. It closes the
  inherited descriptor before deployment so new services cannot retain it.
  Lock contention returns status 75 with a busy message. Other failures retain
  the child command's status and error output.
- GDM invokes Guix's `ewm-session`. It executes
  `$HOME/.local/state/nix/profiles/home-manager/home-path/bin/ewm-start`
  and forwards all arguments. If the launcher is absent, it writes an error
  to stderr and exits with status 1. Deploy both profiles before EWM login.
- `ewm-start` clears `EMACSLOADPATH` and `EMACSNATIVELOADPATH`. It starts
  Nix `emacs-pgtk` with the EWM package paths, `--fg-daemon=ewm`,
  `-l ewm`, and `-f ewm-start-module`.
- API / RPC entrypoints:
- CLI surfaces:
- Event/webhook consumers:
- Repository-detected surfaces: shell

## Data Ownership
- Source-of-truth tables/collections: `gateway.json` is the single owner of how
  an agent reaches a model -- addresses, published ports, the secret's *name*,
  and the managed Claude model catalogue: slot -> id plus the
  `contextWindow` and `maxTokens` ceilings the gateway enforces. Each model also
  has a `cost` block with the registry rates (USD per million tokens, read from
  the gateway's `GET /models` on 2026-10-14). The top-level `promptCache` is
  the Claude provider's prompt-cache lifetime in seconds. `paths.openai` is the
  OpenAI API root without `/v1`; Headroom appends the versioned operation path.
  Existing OpenAI model metadata remains in the user's Pi provider file.
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
| pi | `~/.pi/agent/models.json` | `lego-claude`, optional `lego-openai`, and their direct variants | Claude uses `apiKey: "!<cmd>"`; existing OpenAI authentication is preserved |
| Caveman Code | `~/.cave/agent/models.json` | `lego-claude` | `apiKey: "!<cmd>"` |
| Claude Code | none; wrapper-supplied environment | n/a | `ANTHROPIC_AUTH_TOKEN` exported at process start |

Pi's managed Claude models get `cost` and `promptCache`. Cache warming needs
both fields. OpenAI model metadata stays unchanged; its cache lifetime is not
inferred from the Claude setting. Omp gets no `cost`, because an unknown key
can disable all its custom providers.

On M-02877, Pi names Headroom as the upstream: its root for `lego-claude`,
and `/v1` for the existing `lego-openai` provider. Caveman's extension selects
`/w/pi/compat/lego-claude` or `/w/pi/compat/lego-openai/v1` after its route and
recovery checks pass. The mounts forward the bearer and `x-headroom-cwd`.
Headroom has separate approved Anthropic and OpenAI targets. An empty
`x-api-key` override is not used on the managed proxy route.

`lego-claude-direct` and `lego-openai-direct` keep an explicit path to the
approved gateway without local proxies. The OpenAI direct variant copies the
existing model and authentication data, but omits the local project header.
The other Anthropic harnesses continue to use Headroom as their first hop.

The credential is never a value in this repository. It crosses as a *command*
that prints it when an agent process starts, so it reaches neither the store nor
the work tree. The three pi-family harnesses resolve `!command` themselves.
Claude Code has no equivalent marker, so its wrapper runs the lookup and exports
the documented variable -- the same technique the zsh export of
`CHORUS_API_KEY` uses (`chorus-api-key`, `modules/M-02877/agent-integrations.nix`).

Ownership is partial. Pi's file stays writable. Activation replaces the two
managed Claude blocks, changes only the existing OpenAI route and project
header, and derives its direct variant. It preserves model catalogs,
authentication, other headers, and unrelated providers. The merge lives in
`modules/agent-providers/pi-providers.jq`; its regression script covers repeat
activation, missing providers, and incompatible APIs. An incompatible OpenAI
API keeps that provider unchanged and emits a specific warning; Claude still
updates. Invalid JSON leaves the existing file unchanged. The merge never
creates an incomplete OpenAI provider.

Omp and Caveman Code files retain their seed-only behavior. Pi's selected
default is in `settings.json` and is not reset by provider activation.

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
packages, with `beads` providing the `bd` command. On Darwin, Homebrew has no
beads: `~/bin/bd` wraps the BTS box companion's `~/.local/bin/bd`, and Dolt
comes from Homebrew. Codex, Cursor, and Git hook integrations all invoke `bd`
directly. On M-02877, pi gets `pi-beads-extension`, which also only runs `bd`
(agent side: `bd prime` in the system prompt and through compaction, `/beads:*`
commands). `@soleone/pi-tasks`, the human-side `/tasks` browser, was removed on
2026-10-08 (`piAgent.removedPackages`): nobody used it. The Rust
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
| `~/.pi/agent/mcp.json` | pi's built-in MCP config. Activation merges the declared `piAgent.mcpServers` in by name (`nixos` on every host; `chorus`, `github-spaces`, `codegraph` and `xmemory-bfc0e617` on M-02877), deletes each `piAgent.removedMcpServers` name, and keeps every other entry. M-02877 deletes `context-mode`: the context-mode pi package registers its tools through its own MCP bridge, and the entry started a second server with 11 duplicate tools (den#55). Credentials are `${VAR}` or `!command` values, never literals | `modules/pi.nix` |
| `~/.caveman/caveman.yaml` | Read-only Home Manager configuration. Default Anthropic and OpenAI upstreams use the approved gateway. The `lego-claude` and `lego-openai` compat mounts use Headroom and forward `x-headroom-cwd`; Claude sets `wire_dialect: anthropic`, and OpenAI sets the documented empty dialect. Loopback requires `CAVE_SSRF_ALLOWLIST=127.0.0.1`, which both `caveman-proxy-serve` and the pi shim export, so a hook-started proxy can reach Headroom too. `caveman-proxy-serve` stops a hook-started (`owner: wrap`) proxy that holds port 8787 | `modules/M-02877/token-toolchain.nix` |
| `~/.pi/agent/settings.json` `skills` | pi's skill filters. Activation adds each declared `piAgent.skills` entry that is missing, after the existing entries, and never deletes one. On M-02877 the one entry is `-~/.agents/skills/research`: see pi Team Integrations | `modules/pi.nix` |

## Atuin Threads
`programs.atuin.settings` in `modules/shared-devtools.nix` turns on Atuin Threads (needs Atuin 18.24 or newer): `threads.capture = true`, with `daemon.enabled` and `daemon.autostart` so the daemon records agent sessions. Atuin syncs them end-to-end encrypted through the `sync_address` that `modules/worldofgeese.nix` sets. `atuin resume` resumes a thread, and `atuin threads list`, `search` and `import` read and backfill them. `~/.config/atuin/config.toml` is a read-only store file, so `atuin config enable` fails; change settings in Nix. Output capture (`pty_proxy`, `output`) stays off: it wraps the shell PTY, and the default shell is brush, which Atuin does not officially support (the shim in `modules/shared-devtools.nix` runs the bash init). The `atuin` MCP server for pi comes from `atuin mcp install pi`, which writes `~/.pi/agent/mcp.json`; the pi activation merges by name and keeps entries it does not manage.

## uv Tools
`programs.uv.tool.packages` in `modules/shared-devtools.nix` declares every uv tool on every host. Activation installs and upgrades each entry. `prune = true` uninstalls each uv tool that is not declared, so a manual `uv tool install` lasts only until the next switch. To keep a tool, add it to the list.

The owner wants the latest CPython everywhere. Activation sets `UV_PYTHON` to `uvPython`: Python 3.15 on Linux, and 3.13 on darwin until libsql publishes macOS wheels newer than cp313 (tursodatabase/libsql-python#106).

| Tool | Source | Why |
|---|---|---|
| `crucible-llm` | darwin only: git (`jkitchin/crucible` main), unpinned (latest on every switch) | PyPI 0.1.0 is stale. Unpinned on purpose, like `xmemcli`: an upstream push runs on darwin at the next switch without review. On Linux `crucible` is instead the Nix package `modules/_pkgs/crucible-llm.nix`, built on Python 3.15 from the `crucible-src` input with libsql built from source (`libsql-python-src`, the head of tursodatabase/libsql-python#112, because libsql 0.1.11 cannot build for 3.15). Its checks run with `git` on the path, and `test_version_option_does_not_need_distribution_metadata` is disabled because it replaces `PYTHONPATH` with the source tree, which hides Nix's dependencies. Prune removes any Linux uv install so it cannot shadow the package. Repoint `libsql-python-src` to tursodatabase once a libsql release includes PyO3 0.29 or newer. |
| `xmemcli` | PyPI, unpinned (latest on every switch) | The xmemory CLI. xmemory's install instructions name this PyPI package. Unpinned on purpose: the owner wants the latest release of every tool. |

## Independent Reviewer Interface

`reviewerAgent.md` is the repository-specific staged-change brief. Reviewer-agent's
brief composer discovers that name at the canonical Git common root and supplies
its content. The launcher must not append the brief a second time. The Claude
Code adapter uses Pi's read-only Git extension. This is separate from the
GitHub `pr-reviewer` daemon. Its source stays in a permanent external checkout.

`modules/M-02877/token-toolchain.nix` supplies `~/.local/bin/reviewer-pi` for the
adapter's `piBin` setting. The launcher loads the read-only Git extension and
the mandatory Decapod gate, but excludes unrelated global extensions and MCP
servers. The main coding session keeps its normal tools. A real staged-diff
probe lost source behind recovery pointers with global compactors; the isolated
process returned all three sentinels from the full 30,964-byte diff.
The backend and launcher path use reviewer-agent's own state APIs. The launcher
must be deployed and selected before this installed adapter is enabled.

Installation does not enable commit review or Stop supervision. Each feature
has an independent switch and needs the operator's risk-acceptance receipt.
Host reload, hook trust where required, and the first real reviewed operation
remain separate checks. Source inspection and test results cannot prove them.

The Codex adapter of reviewer-agent 1.4.8 remains uninstalled: its release test
`test_reviewer_launch_environment_remains_stable` fails with SSH commit signing
when Git inherits a nonexistent `TMPDIR`. Signing and the test stay enabled.

## pi Team Integrations (M-02877)
`modules/M-02877/agent-integrations.nix` connects pi, and the other agents on
the work Mac, to the team services in LEGO/devrel-infra. Nothing here is
installed on the personal hosts.

| Service | Endpoint | Credential | Consumers |
|---|---|---|---|
| Chorus (`projects/aws-chorus`, server v0.24.0) | `http://127.0.0.1:3870/api/mcp`, through the `chorus-team-tunnel` launchd agent | `CHORUS_API_KEY` from `chorus-api-key`: secretspec, else the last-known-good cache `~/.local/state/chorus-api-key.cache`; agent "Tao's Key" | interactive pi through `mcp.json` and `@chorus-aidlc/chorus-pi@0.23.0`; the `chorus-pi-daemon` launchd agent. Both get `CHORUS_URL` and `CHORUS_SUBMIT_GATE=block` from `chorusEnv` |
| Team Signet (`projects/aws-signet`) | `http://127.0.0.1:3860` through `signet-team-tunnel` | `~/.config/signet/token`, scoped to agent `tao.hansen` | the `signet-auto-curator` launchd agent (`SIGNET_TEAM_URL`; the curator reads the token file itself), and a shell with `SIGNET_STORE=team`, where the `_signet_store` precmd hook exports `SIGNET_DAEMON_URL=http://127.0.0.1:3860` and `SIGNET_API_KEY` |
| Personal Signet (container) | `http://127.0.0.1:3850` | none: the daemon binds loopback only | every Signet client, whatever the repository: `SIGNET_DAEMON_URL`, `SIGNET_TEAM_URL` and `SIGNET_AGENT_ID` in the session environment (`home.sessionVariables`) and in the Chorus pi daemon's. No shell exports the team key unless `SIGNET_STORE=team`. |
| Gateway auth shim (`signet-gateway-shim`) | `http://127.0.0.1:3851` to the LEGO gateway (`gateway.claudeUrl`) | `LEGO_GATEWAY_API_KEY`: secretspec, else the cache `~/.local/state/gateway-key.cache`, through `gateway.keyCommand` (`SHIM_TOKEN_COMMAND`), the same source as pi | the personal Signet's dreaming and other non-acpx executors |
| Team Friendship Hour (`projects/aws-tfh`) | `http://127.0.0.1:3880` through `tfh-tunnel` | none: tfh has no login, so the tunnel is the only access control | a browser |
| Copilot Spaces | `https://api.githubcopilot.com/mcp/x/copilot_spaces` | `gh auth token` (OAuth, no PAT) | the `techwriter` pi agent |
| toolbox-docs (`LEGO/agentic-engineering-community`) | git, pinned rev | gh's git credential | `~/.agents/skills/{diataxis,simple-english,rewrite-slop,rewrite-documentation,write-usecase,edit-confluence-page}`, `~/.pi/agent/agents/techwriter.md` |

`piAgent.packages` entries are `npm:name` or `npm:name@version`; the option
type rejects anything else. Activation installs and removes them through `pi`
itself, so `settings.json` stays pi's file. Since 2026-11-01 the pi packages
track their latest release (the user's decision): an `npm:name` entry has no
version, and each switch runs `pi update` for it, because pi does not update
packages on its own. ponytail, context-mode and pi-beads-extension are
unpinned.

`piAgent.settings` merges other keys into `settings.json` at each switch,
recursively (jq `*`). A declared value wins, and undeclared keys stay. It
runs after the package step, because `pi install` rewrites the file. On
M-02877 it sets `contextMode.excludeTools`.

chorus-pi stays pinned. The Chorus client, chorus-pi and the team server move
together: on 2026-11-11 they moved to 0.24.0 (`chorusVersion`), because the
team server runs 0.24.0 since LEGO/devrel-infra#711. Chorus 0.24.0 adds Agent
Teams, the `chorus_request_review` tool, a `review` role and an optional
`proposalUuid` for `chorus_recommend_team_agent`, and an optional `ideaUuid` on
tasks. All of them are additive, so 0.23.0 clients kept working against the
0.24.0 server until den moved. The personal Signet image is pinned to
`ghcr.io/signet-ai/signet:1.0.1` by digest in `modules/M-02877/darwin.nix`.
Its image supplies both the CLI and daemon. The pin takes effect only when
the container is recreated. Preserve the private workspace and stop the named
job, then rename and stop the old container so the `signet` name is free.
Keep that container until the new daemon, migration, scoped recall, and
connector checks pass. Rollback restores the workspace backup as well as the
old container name; the container alone is not a backup of its bind mount. This change
does not upgrade the team server or authorize additional data sharing.
Image-probe success is not evidence of a completed live upgrade. Release 1.0.1
adds source, memory-scope, session-write, and cross-site protections. Run the
supported `signet sync` after the upgrade to repair connector file modes;
do not weaken these protections to preserve an old caller's behavior.

Chorus 0.23.0 adds a pre-submit read-back gate to chorus-pi (Chorus#631).
`CHORUS_SUBMIT_GATE=block` refuses `chorus_submit_for_verify` for a task that
the agent did not read back with `chorus_get_task` after its last change. It
refuses `chorus_pm_submit_proposal` unless a `chorus_pm_validate_proposal`
after the last draft edit reported the proposal valid. The refusal tells the
agent which call to make. `warn` only shows a TUI notice, and the pi that the daemon wakes has no
TUI.

chorus-pi has a `research` skill, which its idea and proposal skills load as
`/skill:research`. mattpocock/skills has a skill with the same name. The
skills CLI installs that skill in `~/.agents/skills/research`, and topgrade's
`skills` step installs it again at each run. pi keeps the user skill on a name
collision, so `piAgent.skills` excludes `~/.agents/skills/research` from pi
only. Claude Code and Codex keep it. In pi, the mattpocock skill is
`research-notes`, a copy with a different name in `~/.agents/skills`.

## Mahakala Maintenance Interface
| Command or setting | Reads | Writes | Scope | Proof |
|---|---|---|---|---|
| `just deploy-mahakala` | Guix channel files, `flake.lock`, and Mahakala configuration | Mahakala Guix System, Guix Home, and Home Manager profiles | Mahakala only | Each profile reports a new active generation |
| `just guix-pull-system` | `guix/channels.scm` below `justfile_directory()` | Root Guix profile | Mahakala system source | `guix describe` reports the pulled revisions |
| `just deploy-mahakala-system` | `guix/system.scm`, `guix/touchpad-resume.scm` and `guix-packages/` below `justfile_directory()` | Guix System generation | Mahakala only | `guix system describe` reports the new generation |
| `just check-topgrade` | Topgrade settings and stubbed updater commands | No live profiles or containers | Local regression suite | Tests cover selection, failure propagation, and profile compatibility |
| Guix cleanup | Guix package, Home, and System profiles | Expired non-current generations and unreachable store items | Mahakala | A failed selection or deletion stops cleanup with a nonzero exit |
| GitHub CLI skills | Skills with GitHub source metadata | Unpinned managed skills and backups in `${XDG_STATE_HOME:-$HOME/.local/state}/den/skill-backups` | Current user and project | A failed source check, inventory, backup, or update returns a nonzero exit |
| Agent skills | Global skill roots and the active global lock | Global skills and private backups in `${XDG_STATE_HOME:-$HOME/.local/state}/den/skill-backups` | Current user | Inventory, backup, or invalid-lock failures stop the update; unchecked skills and reported updater failures or warnings return a nonzero exit |
| Claude plugin update | Configured marketplaces and plugins | Marketplace-managed plugins | Current user and project | Bare mode does not run conversation hooks; update failures return a nonzero exit |
| Omarchy session launch | Home Manager profile at login | Session tree and compositor path | Future Guix graphical sessions | A profile switch does not change the pinned session tree |
| Omarchy session sync | The caller's `WAYLAND_DISPLAY` and active shell | Hyprland and D-Bus session environment | Current graphical session | A mutable tree defers sync with a message; a sync failure returns a nonzero exit |
| elogind `system-sleep` hook | HID IDs and `hid-multitouch` bindings | `unbind`, then `bind` | Matching `0018:06CB:76AF.*` devices on `post` only | Nonzero exit and stderr on missing devices, different driver or failed writes; `pre` is a no-op |
| `ath10k_pci.reset_mode=1` | `guix/system.scm` kernel arguments | Linux boot command line | QCA6174 on Mahakala | Built `ath10k_pci` module reports `1` as warm-only reset; runtime proof waits for the next planned boot |

These commands do not force an immediate reboot. The next planned boot verifies the Wi-Fi recovery trial.

## Darwin Deploy Preflight
| Command or file | Effect | Exit |
|---|---|---|
| `scripts/cask-app-preflight.sh` (first step of `just deploy-darwin`) | Runs `brew update`; reinstalls into `~/Applications` every app cask whose recorded appdir is not owned by the user and that is outdated (`brew outdated --cask`, non-greedy, the set that `brew bundle` upgrades) or an empty shell, parking and restoring its CLI symlinks, trashing the old copy when the appdir is writable and otherwise printing an optional admin `rm -rf`; moves a Caskroom backup left by a failed upgrade to `~/.Trash` when the live app exists; lists the apps of outdated casks that have non-user-owned files | 0 = proceed; 1 = a reinstall failed (Caskroom record restored), or prints the `osascript ... chown -R` fix, and stops the deploy |
| `scripts/deploy-freshness.sh` (first step of `just deploy-darwin`) | Runs `git fetch origin main` (30 s limit; on failure it uses the last fetched ref), then requires that `HEAD` contains `origin/main`. `DEN_DEPLOY_STALE=1` skips the check, for a rollback on purpose | 0 = proceed; 1 = `HEAD` does not contain `origin/main`; it lists the missing commits and stops the deploy |
| `scripts/decapod-deploy-backup.sh` (in the `just deploy-darwin` lock, just before `darwin-rebuild switch`) | Evaluates the decapod package of Home Manager's `home.packages` for dktaohan on M-02877. When that store path is not on the symlink path of `/etc/profiles/per-user/dktaohan/bin/decapod`, it copies the main checkout's `.decapod/data/decapod.db` with `sqlite3 -readonly` `.backup` to `~/.local/state/den-decapod-backups/<UTC time>-<old>-to-<new>.db`, requires `PRAGMA integrity_check` = `ok` and a non-empty copy, removes a failed or killed copy, and keeps the newest 5 copies (umask 077). `DEN_SKIP_DECAPOD_BACKUP=1` skips it. `just check-decapod-deploy-backup` (in `just check`) tests it with stub `nix` and `sqlite3` | 0 = Decapod does not change, or the copy is made; 1 = the evaluation failed or took more than 30 minutes, it found no decapod package or more than one, or the copy or its check failed; the deploy stops |
| `just deploy-darwin` lock (`/usr/bin/lockf -k -t 0 /tmp/den-darwin-switch.lock`, held from `scripts/cask-app-preflight.sh` through `darwin-rebuild switch`) | Allows one switch at a time; `sudo -H ... darwin-rebuild switch` stays the direct command of `sh -c`, so the sudoers rule matches | 0 = deploy ran; 75 = another switch holds the lock (the recipe prints `error: another switch is running` and exits 75); other = the failing step's status |
| `just update-darwin` (topgrade "Flake inputs" on M-02877) | `nix flake update` of every root input except `darwin-skip-inputs`, under the same 900 s SIGKILL guard as `just update` | nix's exit status |
| `just cachix-push [target]` | `target` starting with `/` is pushed as a store path (after `readlink -f`); otherwise it is a flake attribute that is built, then pushed | cachix's exit status; callers treat failure as a warning. On M-02877 the usual cause is a locked Mac: the Secure Enclave age key that decrypts `CACHIX_AUTH_TOKEN` works only while it is unlocked, so `just deploy-darwin` says so, and the next unlocked deploy pushes the whole closure |
| `just ghcr-login` (M-02877) | Replaces the `ghcr.io` internet-password item (security domain `com.apple.container.registry`) with gh's token under an any-app ACL | `security`'s exit status |
| `/etc/homebrew/brew.env` | `HOMEBREW_NO_ENV_HINTS=1`, `HOMEBREW_SERVICES_NO_DOMAIN_WARNING=1` for every brew invocation | n/a |

## Dagger ci Module

`.dagger/modules/ci` is a public Go module. It names no host, account or
company: each repository gives those as settings in its own `dagger.toml`
(plan D6). The plan had AEC (LEGO/agentic-engineering-community) install
it at a pinned commit (plan, Shared module interface). AEC rolled back its
Dagger CI on 2026-11-03 and does not use the module. So the settings that
AEC task M added in den PRs #100, #102, #103, #104 and #106 (glob
`riskyPaths`, the author `"*"`, `checkName`, `riskyExecutableBit`, the
manifest field allowlist, `approve-bot-runs`, `ci:workflow-isolation`,
`statusPrefix` and the review gate, `forkPolicy` and `minReleaseAgeDays`)
were reverted, and the module is again the one of 040a18b.

- **Checks** (`dagger check`): `ci:nix-eval`, `ci:fmt`, `ci:shellcheck`,
  `ci:decapod-overrides`, `ci:decapod-validate`, `ci:automerge-rules` and
  `ci:shepherd-rules`. VALIDATION.md (Dagger Checks) maps them to the
  `just check` steps. To run
  one check, give its name to `--check`, for example
  `dagger check --check ci/nix-eval`.
- **CI** (`.github/workflows/dagger.yml`): the job `den/dagger-check` runs
  `dagger check` on a GitHub-hosted `ubuntu-24.04-arm` runner. Branch
  protection on `main` requires `den/dagger-check` and `validate`. The job
  gets no secret and a token that can only read.
- **`automerge-dry-run --token <secret> --pr <n>`** judges an open pull
  request by the merge rules, and prints the verdict and the merge method.
- **`automerge-replay --token <secret> [--count 30]`** judges the newest
  merged pull requests (1 to 100) as of their merge, and prints a Markdown
  table.
- **`shepherd --token <secret> [--dry-run] [--merge]`** (plan P3) asks the Codex
  connector to review the head of each open pull request that has no review
  of its head, and prints a Markdown table of its steps. A new pull request
  waits 10 minutes for the automatic review of Codex. After the first summary
  of Codex, each new head gets a request at once, because Codex reviews by
  itself only when a pull request opens. The shepherd asks again after 20
  minutes, and after 3 requests it adds the label `needs-human` with a
  comment. Only the requests of its own login count, because anyone can
  comment on a public repository. It skips drafts, the stop labels and
  authors outside `authors`, and it needs
  `reviewer = "app/chatgpt-codex-connector"`. `ci:shepherd-rules` tests its
  steps. The table also gives the verdict of the merge rules for each pull
  request, in the words of `automerge-dry-run` (plan P4, first step). The
  workflow `.github/workflows/shepherd.yml` runs it after each `dagger` run,
  after each new or edited comment, by hand and every 15 minutes, with the
  token `DEN_SHEPHERD_TOKEN`. With `--merge` (plan P4, step 2), which
  `shepherd.yml` passes, it merges at most one pull request in each run
  that the merge rules accept, pinned to the head commit that the rules
  judged. The token then needs write access to contents.
- **Write boundary.** `automerge-dry-run` and `automerge-replay` only read
  GitHub. The shepherd writes only the request comment `@codex review`, the
  label `needs-human` and its comment, and with `--merge` the merge of at
  most one pull request in each run. No function sends a review event or
  writes a status.
- **Nightly bump** (plan P6). `.github/workflows/bump.yml` runs
  `scripts/bump-flake-inputs.sh` at 01:17 UTC with `DEN_SHEPHERD_TOKEN`. It
  writes only the branch `bump/flake-inputs` and its pull request: the
  updated `flake.lock`, the renewed `reviewed_sources_digest`, the section
  "Flake Input Updates" of OPERATIONS.md and the spec refresh of
  `decapod validate`. When the update moves the Decapod of `flake.lock` to a
  new release, the bump installs it. Then it writes `AGENTS.md`, `CLAUDE.md`,
  `CODEX.md` and `GEMINI.md` again with `decapod init with --all --force
  --no-specs --no-ci`, as `just decapod-refresh` does, and it keeps
  `.decapod/config.toml`. Then validate writes the release into
  `.decapod/managed/Dockerfile.decapod` and the manifest. Since Decapod
  0.125.0, validate does not overwrite the entrypoints of an older release.
  So the bumps of 2026-11-04 (0.125.0) and 2026-11-05 (0.126.3) kept the old
  header, and the entrypoint check failed. CI installs the
  release in the header of `AGENTS.md`, so CI and the hosts run the same
  Decapod after the merge. A rev before its release on crates.io keeps the
  old header, and the bump warns.
- **Settings** (`[modules.ci.settings]`): `repository` (owner/name),
  `authors` (a bot is `app/<login>`), `reviewer` (the login whose review of
  the head counts) and `riskyPaths` (path prefixes that a person merges).
  Each one is optional, and an empty value refuses.
- **Incomplete data refuses.** When GitHub has more changed files, check
  contexts or label events than one query reads, the rules refuse.
- **Branch protection.** The live rule `protected` reads GitHub's
  `mergeStateStatus` and accepts only `CLEAN` or `HAS_HOOKS`. GitHub computes
  that value from the branch protection of the base, so a required check that
  has not started yet also refuses. An admin token can pass branch
  protection, so the rules do not leave this to GitHub. A replay skips this
  rule, as it skips `open` and `mergeable`.

The token is a Dagger secret, for example `env://GH_TOKEN`. On M-02877,
`DAGGER_ENGINE=container+podman://den-dagger-engine` is a session variable.
Make the container once with `just dagger-check`, then call for example
`dagger call ci automerge-dry-run --token env://GH_TOKEN --pr 73`.

## Mother Recovery Commands

`scripts/fleet-maintenance/mother_recovery.py` exposes `plan`, `prepare`, `stream RUN_ID`, and `cleanup RUN_ID`. The default `plan` command reads state without snapshots or filesystem changes. `prepare` returns a JSON receipt with the run identifier, archive size, and SHA-256. A ready receipt requires successful archive creation and deletion of the temporary source snapshots.

`stream RUN_ID` writes binary archive data to stdout. Its caller must direct those bytes to a private file, not a text log. `cleanup RUN_ID` requires the exact owned run identifier. It checks the private directory, state, and any remaining snapshot UUID before deletion.

The helper refuses unknown persistent mounts, source escapes, substituted symlinks, and unsupported subvolume coverage. `container_identity` sorts complete mount records but preserves the order of `Env`, `Cmd`, and `Entrypoint`. A change to a mount source or its access mode must still stop preparation.

Zerobyte 0.44 uses its organization recovery key for a new repository. `customPassword` only selects a key when `isExistingRepository` is true. An API response that accepts the field does not prove independent recovery. The native Restic test must use the exported organization key.

`mother_checkpoint.py --config FILE` checks local prerequisites and the dedicated Zerobyte binding. `--execute` also prepares, transfers, backs up, restores, and cleans the new source. The configuration identifies the two resources, private paths, secret files, and approved binding hash. The caller prints a bounded JSON result and excludes external program output from its error text.

`completed_snapshot` requires a newer `lastBackupAt`, status `success`, no error, and no active backup task. It also requires a new snapshot identifier, the correct job tag, the expected source path, and a timestamp after the trigger. A `warning` result cannot pass.

## Deploy Report Issues

`scripts/deploy-report.py [--dry-run]` writes issues titled `deploy: <host>: <step>` with the label `deploy-report` in `worldofgeese/den`. The title is the deduplication key. The report opens an issue for a new failing step and closes an open one when a reachable host passes that step. `--dry-run` prints the planned changes and writes nothing. Each NixOS host must provide `/etc/den-revision`, the `BUILD_ID` line of `/etc/os-release`, and SSH access from M-02877 as configured in `~/.ssh/config`.

## Doom Wayland clipboard

On Linux Wayland sessions with `wl-paste` available,
`modules/doom.d/config.el` installs `my/wayland-paste` as Emacs's
`interprogram-paste-function`. It requests UTF-8 text without a trailing
newline and returns it only when it differs from the current kill-ring entry;
unchanged clipboard text produces no insertion. This is a text interface only:
image clipboard formats are attached to Codex as files rather than pasted as
terminal input.

## Guix host interfaces on mahakala

Three interfaces in `guix/system.scm` and `guix/home-configuration.scm` carry
ownership that is easy to break:

- `~/.local/state/<name>.pid` is the handshake between `podman run` and the home
  Shepherd: the container services pass `--pidfile` for that path and declare
  `(pid-file …)` on the same one. Shepherd's default 5 s `pid-file-timeout` is
  otherwise a race against the daemon's own startup, and a timed-out start is
  never retried. Anything that changes the container image, its entrypoint or its
  start-up cost affects this interface; check `herd status <name>` after a change.
- `/etc/resolv.conf` has exactly one writer here: `tailscaled`. The rosenthal
  package prepends openresolv's `sbin` to the `tailscaled` wrapper's `PATH`, and
  openresolv refuses to adopt a file carrying Tailscale's own signature, which
  produced `resolvconf: signature mismatch: /etc/resolv.conf` and the health
  warning `Tailscale failed to set the DNS configuration of your device`.
  `tailscale-direct-resolv` strips that single `PATH` entry and fails the build if
  the wrapper no longer references it; Tailscale then writes the file directly
  (first line `# resolv.conf(5) file generated by tailscale`) and restores it on
  shutdown. Guix's own `networking` resolvconf service must not be re-enabled
  beside it.
- The webcam `0c45:6723` (USB `1-5`) re-enumerated 218 times in this machine's
  lifetime — `USB disconnect, device number N` then `new high-speed USB device`
  — alongside `xhci_hcd 0000:00:14.0: Event dma … status 6 not part of TD`. TLP's
  `usb-blacklist "0c45:6723"` keeps runtime autosuspend off for that device
  (`/sys/bus/usb/devices/1-5/power/control` is `on`) and its udev rule re-applies
  the setting on every re-enumeration, so the port is no longer suspended out from
  under the device. Do not remove the blacklist as cosmetic noise.

<!-- decapod:codebase-attestation:start -->

## Codebase Attestation

- Repository signal fingerprint: `f8c5bb93d8015d31c23ef0a27e99bcdddbdd913e83783c675498269d924449b9`
- Significant implementation surfaces: `.beads/` (1 files), `.dagger/` (12 files), `.github/` (5 files), `README.md/` (1 files), `docs/` (2 files), `modules/` (2 files), `scripts/` (19 files), `terraform/` (1 files)
- Refreshed from the current codebase by `decapod rpc --op specs.refresh`
<!-- decapod:codebase-attestation:end -->
