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
  `contextWindow` and `maxTokens` ceilings the gateway enforces. Each model also
  has a `cost` block with the registry rates (USD per million tokens, read from
  the gateway's `GET /models` on 2026-10-14). The top-level `promptCache` is
  the provider's prompt-cache lifetime in seconds.
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

pi's models get `cost` and `promptCache`. pi keeps a prompt cache warm during a
long tool run only for a model that has both, and it shows a session cost only
when `cost` is set. omp gets no `cost`, because one unknown key disables every
custom provider in omp. On M-02877, pi's `lego-claude` first goes to Caveman's
`lego-claude` compat mount (`http://127.0.0.1:8787/compat/lego-claude`,
`agentProviders.pi.baseUrl`), then to Headroom, and then to the gateway's
`/claude` endpoint. It also sends `x-headroom-cwd` (OPERATIONS.md, "pi through
the chain"). On every host, den also writes `lego-claude-direct`: the same
models, straight to the gateway's `/anthropic` endpoint, for a session that
skips the proxies. The other harnesses use Headroom as their first hop.

The credential is never a value in this repository. It crosses as a *command*
that prints it when an agent process starts, so it reaches neither the store nor
the work tree. The three pi-family harnesses resolve `!command` themselves.
Claude Code has no equivalent marker, so its wrapper runs the lookup and exports
the documented variable -- the same technique the zsh export of
`CHORUS_API_KEY` uses (`chorus-api-key`, `modules/M-02877/agent-integrations.nix`).

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
| `~/.pi/agent/mcp.json` | pi's built-in MCP config. Activation merges the declared `piAgent.mcpServers` in by name (`nixos` on every host; `chorus`, `github-spaces` and `codegraph` on M-02877), deletes each `piAgent.removedMcpServers` name, and keeps every other entry. M-02877 deletes `context-mode`: the context-mode pi package registers its tools through its own MCP bridge, and the entry started a second server with 11 duplicate tools (den#55). Credentials are `${VAR}` or `!command` values, never literals | `modules/pi.nix` |
| `~/.caveman/caveman.yaml` | Caveman's proxy config, a read-only Home Manager file. It holds a safe `anthropic` upstream (the gateway's `/claude`) and pi's `lego-claude` compat mount: Headroom as `base_url`, `wire_dialect: anthropic`, `forward_headers: [x-headroom-cwd]`. The proxy also needs `CAVE_SSRF_ALLOWLIST=127.0.0.1` for that loopback upstream | `modules/M-02877/token-toolchain.nix` |
| `~/.pi/agent/settings.json` `skills` | pi's skill filters. Activation adds each declared `piAgent.skills` entry that is missing, after the existing entries, and never deletes one. On M-02877 the one entry is `-~/.agents/skills/research`: see pi Team Integrations | `modules/pi.nix` |

## pi Team Integrations (M-02877)
`modules/M-02877/agent-integrations.nix` connects pi, and the other agents on
the work Mac, to the team services in LEGO/devrel-infra. Nothing here is
installed on the personal hosts.

| Service | Endpoint | Credential | Consumers |
|---|---|---|---|
| Chorus (`projects/aws-chorus`, server v0.23.0) | `http://127.0.0.1:3870/api/mcp`, through the `chorus-team-tunnel` launchd agent | `CHORUS_API_KEY` from `chorus-api-key`: secretspec, else the last-known-good cache `~/.local/state/chorus-api-key.cache`; agent "Tao's Key" | interactive pi through `mcp.json` and `@chorus-aidlc/chorus-pi@0.23.0`; the `chorus-pi-daemon` launchd agent. Both get `CHORUS_URL` and `CHORUS_SUBMIT_GATE=block` from `chorusEnv` |
| Team Signet (`projects/aws-signet`) | `http://127.0.0.1:3860` through `signet-team-tunnel` | `~/.config/signet/token`, scoped to agent `tao.hansen` | every Signet client: `SIGNET_DAEMON_URL`, `SIGNET_AGENT_ID` and `SIGNET_API_KEY` in the session environment, and in the daemon's |
| Personal Signet (container) | `http://127.0.0.1:3850` | none: the daemon binds loopback only | interactive zsh sessions inside a repository whose origin matches `personalSignetRemotes` (`modules/M-02877/agent-integrations.nix`): the `_signet_store` chpwd hook exports `SIGNET_DAEMON_URL`, and harnesses started from that shell inherit it. `SIGNET_STORE=personal` or `team` overrides the choice. |
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

chorus-pi stays pinned. The Chorus client, chorus-pi and the team server move
together: on 2026-10-23 they moved to 0.23.0 (`chorusVersion`), because the
team server runs 0.23.0. The personal Signet container is pinned too, at
`ghcr.io/signet-ai/signet:0.238.0` (`modules/M-02877/darwin.nix`), the release
that team Signet runs. The container reads that pin only when it
is created. To move a running container to a new pin, back up `~/.agents`,
boot the `signet-container` agent out, run `podman rm -f signet`, and
bootstrap the agent again.

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
| `just deploy-mahakala-system` | `guix/system.scm` and `guix-packages/` below `justfile_directory()` | Guix System generation | Mahakala only | `guix system describe` reports the new generation |
| `ath10k_pci.reset_mode=1` | `guix/system.scm` kernel arguments | Linux boot command line | QCA6174 on Mahakala | Built `ath10k_pci` module reports `1` as warm-only reset; runtime proof waits for the next planned boot |

These commands do not force an immediate reboot. The next planned boot verifies the Wi-Fi recovery trial.

## Darwin Deploy Preflight
| Command or file | Effect | Exit |
|---|---|---|
| `scripts/cask-app-preflight.sh` (first step of `just deploy-darwin`) | Runs `brew update`; reinstalls into `~/Applications` every app cask whose recorded appdir is not owned by the user and that is outdated (`brew outdated --cask`, non-greedy, the set that `brew bundle` upgrades) or an empty shell, parking and restoring its CLI symlinks, trashing the old copy when the appdir is writable and otherwise printing an optional admin `rm -rf`; moves a Caskroom backup left by a failed upgrade to `~/.Trash` when the live app exists; lists the apps of outdated casks that have non-user-owned files | 0 = proceed; 1 = a reinstall failed (Caskroom record restored), or prints the `osascript ... chown -R` fix, and stops the deploy |
| `scripts/deploy-freshness.sh` (first step of `just deploy-darwin`) | Runs `git fetch origin main` (30 s limit; on failure it uses the last fetched ref), then requires that `HEAD` contains `origin/main`. `DEN_DEPLOY_STALE=1` skips the check, for a rollback on purpose | 0 = proceed; 1 = `HEAD` does not contain `origin/main`; it lists the missing commits and stops the deploy |
| `just update-darwin` (topgrade "Flake inputs" on M-02877) | `nix flake update` of every root input except `darwin-skip-inputs`, under the same 900 s SIGKILL guard as `just update` | nix's exit status |
| `just cachix-push [target]` | `target` starting with `/` is pushed as a store path (after `readlink -f`); otherwise it is a flake attribute that is built, then pushed | cachix's exit status; callers treat failure as a warning |
| `just ghcr-login` (M-02877) | Replaces the `ghcr.io` internet-password item (security domain `com.apple.container.registry`) with gh's token under an any-app ACL | `security`'s exit status |
| `/etc/homebrew/brew.env` | `HOMEBREW_NO_ENV_HINTS=1`, `HOMEBREW_SERVICES_NO_DOMAIN_WARNING=1` for every brew invocation | n/a |

## Dagger ci Module

`.dagger/modules/ci` is a public Go module. It names no host, account or
company: each repository gives those as settings in its own `dagger.toml`
(plan D6). AEC installs it at a pinned commit (plan, Shared module
interface).

- **Checks** (`dagger check`): `ci:nix-eval`, `ci:fmt`, `ci:shellcheck`,
  `ci:decapod-overrides`, `ci:decapod-validate`, `ci:automerge-rules`,
  `ci:shepherd-rules`, `ci:approve-bot-runs-rules`, `ci:workflow-isolation`,
  `ci:workflow-isolation-rules`, `ci:review-gate-rules` and
  `ci:release-age-rules`. VALIDATION.md (Dagger Checks) maps them to the
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
- **`shepherd --token <secret> [--dry-run]`** (plan P3) asks the Codex
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
  token `DEN_SHEPHERD_TOKEN`.
- **`approve-bot-runs --token <secret> --sha <sha>`** (`approve.go`)
  approves the `pull_request` runs that GitHub holds on a head that a job
  pushed with its `GITHUB_TOKEN`. A repository calls it after such a push,
  with the token of that job. GitHub gives a held run the status
  `completed` and the conclusion `action_required`. The function lists the
  held runs of the head (`GET /repos/{owner}/{repo}/actions/runs` with
  `head_sha` and `status=action_required`). It approves each run of the
  repository with `POST /repos/{owner}/{repo}/actions/runs/{id}/approve`,
  which needs `actions: write`. It lists again every 10 seconds. It stops
  when no run of the repository waits 30 seconds after the last approval,
  or after 3 minutes. Before the first approval, it looks for the full 3
  minutes, because the runs can appear late. A run of a fork or of another
  head stays held for a person. The function fails only when runs waited
  and GitHub approved none of them: then the token needs `actions: write`.
  A list that fails does not fail the function, and the report gives the
  count and the last error. Without `approveBotRuns = true` or a full
  commit SHA, it refuses before it reads the token. No workflow of this
  repository calls it. People push the branches of its pull requests, and
  `bump.yml` pushes with `DEN_SHEPHERD_TOKEN`, so GitHub holds no run.
- **`review-gate --token <secret> [--pr <n>] [--dry-run]`**
  (`reviewgate.go`, plan P4 and part h of AEC task M) is the review gate. It
  posts the commit status `<statusPrefix>/review` on the head of each open
  pull request, or of the pull request `--pr`. The status is `success` when
  the newest review of the exact head by `reviewer` has no open blocking
  finding, and `failure` when it has one. A review of an older head does not
  count, so a new head starts with no status. The function posts a result
  only when the head does not already have that state and description,
  because GitHub keeps at most 1000 statuses for each commit and context.
  With `--dry-run`, it posts nothing. It prints a Markdown table with the
  result, the reason and the action for each pull request. It posts no
  label. Without `statusPrefix`, it refuses before it reads the token. The
  token needs `statuses: write`. No workflow of this repository calls it,
  and the shepherd does not call it.
  - Without `reviewMarker`, the gate reads the reviewer as the merge rules
    do. The head has a review when the rule `reviewed` accepts it, or when a
    completed Codex summary of the head has `has_unresolved_findings: true`.
    It fails when that summary has unresolved findings and the reviewer
    submitted no review of the head. It also fails when a review thread is
    unresolved (the rule `threads`), or when the newest decisive review of
    the reviewer requests changes.
  - With `reviewMarker`, the gate reads the newest review of the head by the
    reviewer that has the block
    `<!-- <reviewMarker> {"open":[{"id":"F1","severity":"blocking"}]} -->`.
    `open` lists the open findings. Each severity other than `note` blocks.
    A block that does not parse, a block without `open`, or two blocks in one
    review fail. Each HTML comment that starts with the marker name is a
    block, also when its JSON does not parse, so a broken block never lets
    an older review count. A comment that starts with a longer name, for
    example `aec-review:v10`, is not a block. Other reviews of that login do
    not count.
- **`release-age --candidates <json>`** (`release.go`, part f of AEC task
  M) is the age rule of the bump targets. A bump gives it the candidates of
  one pin as a JSON list, newest first:
  `[{"version": "v1.2.0", "published": "2026-10-20T12:00:00Z"}]`. For a
  release, `published` is its publish time. For a commit, it is the
  committer date of the commit on the default branch of the upstream
  repository. The function chooses the first candidate in the list that is
  at least `minReleaseAgeDays` old. It lists each newer candidate that it
  skipped, with the reason: its age, no publish time, or a publish time
  after now. With no candidate that is old enough, `chosen` is `null`, and
  the bump keeps the pin. The order of the list decides, not the publish
  time, so a bump gives releases in the order of their versions. The output
  is JSON with `minReleaseAgeDays`, `chosen` and `skipped`. The function
  reads no network and changes nothing. A list that does not parse, an
  unknown field, an item with no version, or text after the list refuses.
  No flow of this repository calls it: the nightly bump of plan P6 runs
  `nix flake update`, which chooses the newest commit of each flake input.
- **Write boundary.** `automerge-dry-run`, `automerge-replay` and
  `release-age` only read. The shepherd writes only the request comment
  `@codex review`, the label `needs-human` and its comment. With `--merge`, it also merges at
  most one pull request in each run that the merge rules accept (plan P4,
  step 2). `approve-bot-runs` writes only approvals of held runs of the
  repository on the head that it gets. `review-gate` writes only the commit
  status `<statusPrefix>/review` on the heads of open pull requests. No
  function sends a review event.
- **Nightly bump** (plan P6). `.github/workflows/bump.yml` runs
  `scripts/bump-flake-inputs.sh` at 01:17 UTC with `DEN_SHEPHERD_TOKEN`. It
  writes only the branch `bump/flake-inputs` and its pull request: the
  updated `flake.lock`, the renewed `reviewed_sources_digest`, the section
  "Flake Input Updates" of OPERATIONS.md and the spec refresh of
  `decapod validate`. When the update moves the Decapod of `flake.lock` to a
  new release, the bump installs it, and validate writes that release into
  `AGENTS.md`, `CLAUDE.md`, `CODEX.md`, `GEMINI.md`,
  `.decapod/managed/Dockerfile.decapod` and the manifest. CI installs the
  release in the header of `AGENTS.md`, so CI and the hosts run the same
  Decapod after the merge. A rev before its release on crates.io keeps the
  old header, and the bump warns.
- **Settings** (`[modules.ci.settings]`). Each setting is optional. The
  `dagger.toml` of this repository sets the first four. Its `riskyPaths`
  have no `*`, and its `authors` do not include `"*"`. It does not set
  `checkName`, `riskyExecutableBit` or the manifest settings. So the globs,
  the author `"*"`, `checkName` and the two file rules do not change its
  verdicts, and its merge rules read no Git tree. It does not set
  `approveBotRuns` or `jobKinds` either, so the module approves no run, and
  `ci:workflow-isolation` reads no workflow and passes. It sets none of the
  five settings of the review gate, so `review-gate` refuses, and the rules
  read no status of the gate. It sets no `forkPolicy`, so the policy is
  `checks-only` and the shepherd takes no fork action. It sets no
  `minReleaseAgeDays`, so `release-age` chooses the newest candidate.
  - `repository`: the GitHub repository, owner/name, that the functions
    read.
  - `authors`: the logins whose pull requests can merge without a person.
    A bot is `app/<login>`, and `"*"` is every author. With no authors, each
    pull request needs a person, and the shepherd gives it checks only.
  - `reviewer`: the login whose review of the head counts. With none,
    nothing merges.
  - `riskyPaths`: a person merges each pull request that changes a matching
    path. A pattern without `*` is a path prefix: `secrets/` matches
    `secrets/a.age`, but not `modules/secrets/a.age`. A pattern with `*` is
    a glob that must match the whole path. `*` matches in one level, and
    `**` as a whole level matches zero or more levels. So `**/*.sh` matches
    `run.sh` and `a/b/run.sh` but not `run.shx`, and `.github/**` matches
    each path under `.github/`. To match a directory and each path under
    it, end the glob in `/**`. Only `*` is special: `?`, `[` and `\` match
    themselves. `matchRiskyPath` in `automerge.go` does the match. With no
    patterns, no path needs a person.
  - `checkName`: when it is set, the rule `required-check` requires that
    the newest run of that check on the head succeeded. A check run or a
    commit status of that name counts. A skipped or neutral run is green
    for the rule `checks`, but it does not count here. A replay judges this
    rule with the runs from before the merge. With no `checkName`, the rules
    leave the required checks to branch protection (the rule `protected`).
    A repository whose branch protection requires no check can be `CLEAN`
    before any check runs, so that repository sets `checkName`.
  - `riskyExecutableBit` (default `false`): when it is `true`, the rule
    `executable-bit` refuses a pull request that adds a file with git mode
    `100755`. It also refuses a pull request that changes the mode of a
    file to `100755`. A file that stays at `100755` needs no person. A
    symbolic link (`120000`) is not an executable file for this rule.
  - `manifestFiles`, `manifestSafeFields` and `manifestSourcePrefix`: the
    rule `manifest-fields` reads each changed file that a `manifestFiles`
    pattern matches. The patterns have the semantics of `riskyPaths`. The
    rule compares the JSON object at the merge base and at the head. A
    file that is not there is an empty object, so a new file adds each of
    its fields. A top-level field outside `manifestSafeFields` that the
    head adds, removes or changes refuses.
  - A top-level array of objects is a list of entries, for example the
    `plugins` of a marketplace. The name of an entry pairs it with the
    entry of the same name, so each entry needs a unique name. In an
    entry, the safe fields can change. `source` can change only to a
    relative path under `manifestSourcePrefix`, for example `./plugins/a`
    under `./plugins/`. A URL, an object, a `..` level or a `\` in a
    source refuses. An entry that the head adds or removes adds or removes
    each of its fields.
  - A manifest file that does not parse as one JSON object refuses. A
    manifest file that is not a regular file, for example a symbolic link,
    also refuses. With no `manifestFiles`, the rule is off. With no
    `manifestSourcePrefix`, each change of a `source` refuses.
  - The two file rules read GitHub's REST API (`readTrees` and `treeFiles`
    in `automerge_files.go`). The compare API gives the merge base of the
    base commit and the head. GitHub lists the changed files against the
    same merge base. The Git trees of the merge base and the head give the
    modes, and the blobs give the text of the changed manifest files.
    `fetch` reads them only when one of the two rules is on.
  - Tests: `ci:automerge-rules` has a glob and a prefix that match and that
    do not match, one glob for each kind of risky path, and a policy with
    no `riskyPaths`. It tests authors empty, set and `["*"]`. It tests `checkName` unset, with no run, and
    with a run that succeeded, failed or was skipped. `ci:shepherd-rules`
    tests authors empty, set and `["*"]`.
  - Tests of the file rules (`automerge_files_checks.go` in
    `ci:automerge-rules`): a new file of mode `100755`, a mode that changes
    to `100755`, files that keep their mode, the setting off, a tree that
    GitHub cut and trees that `fetch` did not read. For the manifests: only
    safe fields, an author, `hooks` and `mcpServers`, a new manifest with
    an author, and the setting off. For the sources: a relative path under
    the prefix, a URL, an object, a path outside the prefix and `..`. Also
    an entry without a name, JSON that does not parse and a symbolic link.
    The fixtures read trees and blobs in the JSON of the REST API, and a
    replay keeps the trees. Without the two file rules, each of these
    fixtures that expects a refusal fails.
  - `approveBotRuns` (default `false`): with `true`, `approve-bot-runs`
    can approve held runs. With `false`, the function refuses, and no flow
    of the module approves a run.
  - `jobKinds`: the job-kinds table of `ci:workflow-isolation`, as YAML in
    a TOML string (`workflows.go`). In `dagger.toml`, put the YAML in a
    multi-line literal string (`'''`). `jobs` gives each job a kind, as
    `<workflow file>/<job id>: <kind>`. The kinds are `CHECK` (runs the code
    of a pull request: at most `contents: read`, no secret, no cache),
    `AGENT` (at most `contents: read` and the one secret of
    `secrets.AGENT`, in `agentEnvironment`), `GITHUB` (the job's
    `GITHUB_TOKEN` and the scopes `actions`, `checks`, `contents`, `issues`,
    `pull-requests` and `statuses`), `SCAN` (at most `contents: read` and
    the one secret of `secrets.SCAN`) and `LEGACY`. A `LEGACY` job keeps
    exactly what `legacy` records for it: `permissions`, `secrets`,
    `actions`, `environment`, `keepsToken` and `anyBranch`. `actions` is the
    allowlist, each action pinned to a commit SHA. `localActions` need no
    pin, for example `$/.github/actions/dagger`. Only the `pagesBuild` jobs
    can use `actions/upload-pages-artifact`. Only the `pagesDeploy` jobs
    can use `actions/deploy-pages`, hold `pages` and `id-token` and run in
    `github-pages`.
  - The check also requires `permissions: {}` at the top of each workflow,
    scopes on each job, no `pull_request_target`, and only the events of
    `main` for a workflow with a job of another kind than `CHECK`. If such a
    workflow starts on `workflow_dispatch`, the condition of each such job
    must start with `github.ref == 'refs/heads/main'`, joined to the rest
    with `&&` only. AGENT, GITHUB, SCAN and LEGACY jobs never check out or
    fetch the code of a pull request, also through a pull ref that an
    expression builds. Each checkout sets `persist-credentials: false`,
    except for a `LEGACY` job with `keepsToken`. A job that `jobs` does not
    name fails. A table with a field that it does not know, a kind that does
    not exist, an AGENT job without `agentEnvironment`, or no job, is
    refused. With an empty `jobKinds`, the check is off. A table for this
    repository is a later change: its workflows use other actions, a token
    from the environment `shepherd`, and top-level permissions that are not
    `{}`.
  - Tests: `ci:approve-bot-runs-rules` runs the live approval loop against
    a fake GitHub API (an `http.RoundTripper`) and a fake clock: no runs, runs
    that appear late, some approved and some failing, none approvable (an
    error), the give-up time, a refusal that ends, runs of a fork and of
    another head, a run that GitHub lists again after its approval, a list
    that fails after an approval, and lists that fail. It also tests the
    setting off and SHAs that are not full. `ci:workflow-isolation-rules`
    has a passing fixture with a job of each kind, the 55 rule cases of the
    earlier copy of the check (`docs:workflow-isolation-rule` in
    LEGO/agentic-engineering-community), a case for a guard that a later
    `||` can skip, 10 cases that change the table, and the table checks.
  - `statusPrefix` (default empty): the review gate posts the context
    `<statusPrefix>/review`, for example `aec/review`. GitHub compares
    contexts without case. With no `statusPrefix`, the gate is off, and no
    status is the status of the gate.
  - `reviewMarker` (default empty): the name of the block in the review body
    of the reviewer, for example `aec-review:v1`. With none, the gate reads
    the reviewer as the merge rules do.
  - `secondPersonApproval` (default `false`): with `true`, an `APPROVE` of
    the exact head opens the gate. The `success` names the approver. The
    gate reads the approvals before the review of the reviewer, because an
    approval is the way past a finding that a person judges wrong.
  - An approval counts only on a pull request from a branch of this
    repository. The activity API of this repository does not show the
    pushes to a fork. The approver must be a person with a login, not an
    `app/` login, and must not be the author. GitHub gives no login for a
    deleted account, so its approval does not count, and the gate reads the
    next approver.
  - The approver must have write access:
    `GET /repos/{owner}/{repo}/collaborators/{login}/permission` gives
    `admin` or `write`. GitHub gives `write` for the role `maintain`.
  - The approver must have pushed none of the commits:
    `GET /repos/{owner}/{repo}/activity?ref=refs/heads/<branch>&actor=<login>&per_page=100`
    lists no activity of the approver on the head branch other than
    `branch_deletion`. The gate reads who pushed from the activity API,
    because a pusher can give a commit any author. The gate also checks the
    ref and the actor of each item. A full page of 100 items refuses.
  - The newest decisive review of the approver on the head must be the
    approval. A later request for changes, or a dismissal, takes it back.
    The gate reads the API only for an approval that the snapshot does not
    refuse, so a fork pull request gets no call. After the first approval
    that passes, it reads no other approver.
  - `reviewTimeoutHours` (default `0`): when the gate has no result for a
    head, the head has no status of the gate, and the head is not a draft,
    the gate looks at the check of the head. That is the newest run of
    `checkName`. With no `checkName`, it is the last of the newest checks,
    when all of them are complete. If that check finished this many hours
    ago or more, the row gets the action "needs-human: review by a person:
    approve head X?". The function only reports this action. With `0`, there
    is no timeout.
  - When the head has the `success` of the gate, and no review or approval
    stands now, the gate posts `failure` with "no review or approval of head
    X stands". Without this rule, an approval that a person took back keeps
    the old `success` on the head.
  - `requireReviewGate` (default `false`): with `true`, the rule
    `review-gate` (after `reviewed`) refuses unless the newest
    `<statusPrefix>/review` commit status on the head is `success`. A check
    run with that name does not count. With `requireReviewGate` and no
    `statusPrefix`, the rule refuses. A replay judges the rule with the
    statuses from before the merge.
  - The status of the gate is never evidence for a merge. The rule
    `reviewed` reads only reviews and the Codex summary, so the `success`
    of the gate is not a review. With `statusPrefix`, the `failure` of the
    gate refuses at `checks`, as each failed status does. But the status of
    the gate is not a check that ran, and it is never the check of
    `checkName`. With no `statusPrefix`, a status with the name
    `aec/review` is a usual commit status, as before.
  - For the gate, `prQuery` also reads `isCrossRepository`, `headRefName`,
    the count and the body of the reviews, and the description of each
    commit status. `prCheck.Done` is the time when a check run completed, or
    when a commit status that is not pending was posted. `queryPR` reads a
    pull request, and `fetch` adds the Git trees for the file rules. The
    gate reads no tree.
  - `forkPolicy` (default `checks-only`, also when it is empty): what the
    module does with a fork pull request, whose head branch is in another
    repository. `fork.go` holds the policy, and `forkAction` decides.
  - With `checks-only`, the module does what it did before this setting.
    The merge rules and the shepherd judge a fork pull request as each pull
    request. So a fork pull request from an author outside `authors` gets
    checks only, and a fork pull request from an author in `authors` can
    merge when each rule accepts it.
  - With `review-and-suggest`, a fork pull request goes through the same
    merge rules as a branch of this repository, and it merges when each rule
    accepts it. One action is new. A fork pull request that conflicts with
    its base (`mergeable` is `CONFLICTING`) gets the label `needs-human`
    and a comment from the shepherd. An update of the branch writes to the
    fork, and the token cannot push to a fork. A draft, a pull request with
    a stop label, and a state of `UNKNOWN` get no action. The label then
    stops all automation, so the shepherd adds it once. With `--dry-run`,
    the table says "would add needs-human", and the shepherd posts nothing.
    The shepherd takes the action also without `--merge`.
  - A fork pull request that is behind its base without a conflict merges as
    it is. No function of the module updates a branch, for a fork or for a
    branch of this repository. With branch protection that requires an
    up-to-date branch, GitHub gives such a head the merge state `BEHIND`,
    and the rule `protected` refuses it.
  - A fix for a fork pull request is a suggestion comment, never a push.
    The module has no fixer yet, so this part of `review-and-suggest`
    applies when a fixer comes. A conflict on a branch of this repository
    gets no action from this setting.
  - Another value refuses before a function reads the token. `m.github`
    calls `checkForkPolicy` first.
  - `minReleaseAgeDays` (default `0`): the minimum age of a bump target in
    days, for `release-age`. With `0`, the rule is off, and the function
    chooses the first candidate. A negative value refuses.
  - Tests: `ci:shepherd-rules` runs the shepherd against a fake GitHub API
    (an `http.RoundTripper` for the two GraphQL queries, the label, the
    comment and the merge) for each `forkPolicy`. With `review-and-suggest`:
    a fork that conflicts gets `needs-human` and the comment, also without
    `--merge`, and a dry run only reports it. A fork that each rule accepts
    merges, also when it is behind main. A fork that a rule refuses does not
    merge. A label that is there, a stop label, a draft, a merged pull
    request and `UNKNOWN` get no action, and a failed label fails the run.
    With no setting and with `checks-only`, a fork that conflicts gets no
    action, and a fork that each rule accepts merges. Inverted: a branch of
    this repository that conflicts gets no action. The tables of the three
    values are the same for each pull request with no action. No fixture
    sends an update of a branch or a push. Values that the module does not
    know refuse before a call.
  - Tests: `ci:release-age-rules` tests `chooseRelease` with 7 days for
    releases and for commits by committer date, exactly 7 days, one second
    less, no candidate old enough, no publish time, a publish time after
    now, the order of the list, and no candidates. Switched off (`0`), it
    chooses the newest candidate. Inverted, the newest candidate is old
    enough and nothing is skipped. It also tests the JSON input and output,
    and each refusal.
  - In this module, the login of a bot is `app/<login>`, as `gh` prints it.
    So a repository whose pipeline posts reviews with its `GITHUB_TOKEN`
    sets `reviewer = "app/github-actions"`.
  - Tests: `ci:review-gate-rules` runs `review-gate` against a fake GitHub
    API (an `http.RoundTripper` for GraphQL, the permission and activity
    APIs, and the statuses). It has success and failure for both readings,
    reviews and summaries of an older head, the marker blocks, approvals by
    a second person, and each refusal: the author, a pusher, a fork, read
    access, a bot, an older head, a later request for changes, a dismissal
    and no head branch. It also has the timeout that fires and does not
    fire, the rules of when the gate posts, a dry run, and the checks of the
    arguments. `ci:automerge-rules` tests the rule `review-gate`, the status
    of the gate in `checks` and `required-check`, the settings off, and the
    new fields of the snapshot. `fetch` reads the trees only with a file
    rule.
- **Incomplete data refuses.** When GitHub has more changed files, check
  contexts or label events than one query reads, the rules refuse. When
  GitHub cuts the Git tree of the merge base or the head because it is too
  big for one call (`truncated`), each file rule refuses and names the
  commit. When GitHub has more reviews than the query reads, the review gate
  decides nothing for the head.
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

<!-- decapod:codebase-attestation:start -->

## Codebase Attestation

- Repository signal fingerprint: `bc077343dc762274aa7bb9de55d392d796a2fcefb5b0c25ba35d8d481248637c`
- Significant implementation surfaces: `.beads/` (1 files), `.dagger/` (24 files), `.github/` (5 files), `README.md/` (1 files), `docs/` (2 files), `scripts/` (8 files), `terraform/` (1 files)
- Refreshed from the current codebase by `decapod rpc --op specs.refresh`
<!-- decapod:codebase-attestation:end -->
