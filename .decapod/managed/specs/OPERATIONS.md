# Operations

## Operational Readiness Checklist
- [ ] On-call ownership defined.
- [ ] SLOs and alert thresholds defined.
- [ ] Dashboards for latency/errors/throughput are live.
- [ ] Runbooks linked for all Sev1/Sev2 alerts.
- [ ] Rollback plan validated.
- [ ] Capacity guardrails documented.

## Deployment Model
Describe the operational runtime model, scheduling, and system deployment architecture.

### pr-reviewer (M-02877)
`modules/M-02877/pr-reviewer.nix` runs the PR review daemon as the launchd
agent `com.dktaohan.pr-reviewer`, from a pinned Nix build of upstream
`NicholaiVogel/pr-reviewer` carrying a local patch (git HTTPS auth sent as
Basic, not Bearer, which GitHub's git endpoint rejects).

- **Which repos are reviewed** is the `repos` list in that file. The agent's
  start wrapper runs `pr-reviewer add` for every declared repo missing from
  the runtime config, then `exec`s `pr-reviewer start`. Adding a repo is one
  list entry plus `just deploy-darwin`. Reconciliation is add-only; a
  configured but undeclared repo is logged, not removed. The declared repos
  are LEGO/conference-dashboard, LEGO/devrel-infra,
  LEGO/agentic-engineering-community, LEGO/ai-daily-assistant and
  LEGO/team-friendship-hour.
- **PRs opened before a repo was added** are reviewed too: each poll queues
  every open PR whose head SHA has no recorded review, so the first poll after
  registration picks up the existing backlog.
- **Runtime state** (config.toml with the machine-bound encrypted token,
  keyfile, state.db, managed clones) stays in
  `~/Library/Application Support/pr-reviewer` and is mutated only by the CLI.
- **Never start it by hand.** The pidfile is not a lock, so a manual
  `pr-reviewer start` runs a second daemon that double-reviews every PR.
  Restart with `launchctl kickstart -k gui/$UID/com.dktaohan.pr-reviewer`.
- **Health**: `launchctl print gui/$UID/com.dktaohan.pr-reviewer` (state,
  last exit), `pr-reviewer status` (heartbeat, queue, rate limit), log at
  `~/Library/Logs/pr-reviewer.log`.
- **Gateway auth** uses a dedicated key file,
  `~/Library/Application Support/pr-reviewer/gateway.key` (0600), via a
  `claude` shim on the agent's PATH that adds `--settings` with an
  `apiKeyHelper` reading that file. It must not use the interactive
  secretspec helper: the Secure Enclave key only works while the Mac is
  unlocked, so reviews started under a locked screen failed. The wrapper
  refuses to start if the key file is missing.
- The agent needs `/usr/sbin` (ioreg) and `USER` in its environment: both
  feed the machine key that decrypts the GitHub token, and their absence
  fails only under launchd, never in an interactive shell.
- **Restart only while idle.** A restart during a review leaves that item
  `claimed` with no worker, and recovering it skips the review
  (NicholaiVogel/pr-reviewer#26, #27). Before `launchctl kickstart -k`, wait
  until the daemon has no child processes and `work_queue` has no `claimed`
  rows. If a PR was stranded anyway, `pr-reviewer review owner/repo#N --force`
  reviews it.

#### Live end-to-end test
The private repo `worldofgeese/pr-reviewer-livetest` is a test target that
notifies nobody else. It is deliberately *not* in the declared list.
1. `pr-reviewer add worldofgeese/pr-reviewer-livetest`. This exercises the
   patched HTTPS managed clone. Then restart while idle (above).
2. Open a PR containing a planted bug. Expect a review within the poll interval
   plus review time: 89 s on 2026-10-01, with all three planted bugs found.
3. Push a fix. Expect a follow-up review that marks the findings addressed
   (52 s on 2026-10-01).
4. Close the PR, `pr-reviewer remove worldofgeese/pr-reviewer-livetest
   --purge`, and restart while idle.
For the locked-screen case, lock the Mac between steps 2 and 3. The review
must still post, because the harness never touches the Secure Enclave key.

#### Documentation review
pr-reviewer reviews documentation changes. It does not skip them. Two values
in the runtime configuration file `config.toml` control this. Nix does not
write them.
1. `defaults.skip_docs_only` is `false`. Set it with
   `pr-reviewer config set defaults.skip_docs_only false`.
2. Each `[[repos]]` entry has a `custom_instructions` value. The CLI cannot
   set a value in one repo entry, so you edit `config.toml` by hand. Keep a
   copy of the file first. Then restart the daemon while it is idle.

The instructions tell the reviewer to load four skills from
`~/.claude/skills`: simple-english, rewrite-slop, diataxis and
technical-writer. They also give the path of the managed clone of the repo.
The reviewer runs in an empty temporary directory. Without the path, it cannot
read the source, so it cannot compare the text with the code.

A repo that you add, or that the launchd wrapper adds, has no instructions.
Copy the value from another entry and change the clone path in it.

Prose findings are suggestions. In the live test on 2026-10-02, a page
described a function that did not exist on the default branch. The reviewer
found it, but posted a comment and did not request changes.

### Chorus pi daemon and team integrations (M-02877)
The launchd agent `com.dktaohan.chorus-pi-daemon` runs `chorus daemon --agent
pi --cwd ~/projects`. Chorus wakes a headless `pi --mode rpc` in `~/projects`
when work is assigned to the agent; that pi has this user's file access there,
which is why the served set is one directory. Log:
`~/.local/state/chorus-pi-daemon.log`.

- Credentials. The Secure Enclave identity behind secretspec refuses to
  decrypt while the screen is locked (`errSecInteractionNotAllowed`, -25308).
  The daemon therefore caches `CHORUS_API_KEY` in
  `~/.local/state/chorus-api-key.cache` (0600) after each good read and uses
  the cache when secretspec fails, as the gateway `keyCommand` already does.
  The first start must happen while the Mac is unlocked.
- Versions. Client and `chorus-pi` are 0.21.1, the server v0.20.0. If wakes
  fail with errors about missing endpoints, upgrade `projects/aws-chorus` to
  0.21.1 rather than downgrading the client: 0.21.1 is the first release with
  pi's built-in MCP.
- The Chorus CLI is an npm global (`~/.local/bin/chorus`), installed and pinned
  by activation because the package is the whole Chorus server app.

Team Signet: every Signet client on M-02877 now uses the team pool. The
personal daemon on 3850 still runs; reach it with
`env -u SIGNET_DAEMON_URL -u SIGNET_API_KEY signet ...`. Its remaining
memories were exported on 2026-10-06 to `~/signet-handover/`, in full and as a
filtered `personal-only` copy for the personal machines.

Activation snippets run with Home Manager's activation PATH only: bash,
coreutils, diffutils, findutils, gettext, grep, sed, jq and ncurses. Neither
`/usr/bin` nor the user profile is on it, so `awk` and every other tool must be
named by store path. The first deploy of the pi integrations (den#27) stopped at
`awk: command not found` because the snippets were tested with a login shell's
PATH. Test a new snippet with `env -i PATH=<the PATH line from the generated
activate script> bash`.

pi's Signet extension is installed once by hand with `signet connect pi`
(it writes `~/.pi/agent/extensions/signet-pi.js`, which Signet owns).

## Service Level Objectives
| SLI | SLO Target | Measurement Window | Owner |
|---|---|---|---|
| Availability | 99.9% | 30d | TBD |
| P95 latency | TBD | 7d | TBD |
| Error rate | < 1% | 7d | TBD |

## Monitoring
| Signal | Metric | Threshold | Alert |
|---|---|---|---|
| Traffic | requests/sec | baseline drift | warn |
| Latency | p95/p99 | threshold breach | page |
| Reliability | error ratio | threshold breach | page |
| Saturation | cpu/memory/queue depth | sustained high | page |

## Health Checks
- Liveness:
- Readiness:
- Dependency health:
- Synthetic transaction:

## Incident Response
- Detection:
- Triage:
- Mitigation:
- Communication:
- Post-mortem:

## Rollout Strategy
- Blue/green deployment:
- Canary release:
- Rolling update:
- Feature flags:

## Capacity Planning
- Traffic patterns:
- Resource utilization:
- Scaling triggers:

## Logging
Use structured logging (pino/winston) with request_id, actor, latency_ms, and error_code fields.

## Runbook
### Detect
- Signals that indicate the service/workflow is unhealthy: a deploy
  (`just deploy-darwin`, usually via topgrade) prints repeated
  `substituter 'https://cache.nixos.org' is disabled`, the `failed` copy count
  climbs, and the build total jumps far past normal (4100 instead of ~400).
- Dashboards, logs, and evidence locations: the deploy's terminal output;
  `nix build --dry-run .#darwinConfigurations.M-02877.system` gives the true
  built/fetched counts on a healthy connection.

### Triage
- First bounded checks: `curl -w '%{http_code}' https://cache.nixos.org/nix-cache-info`
  over IPv4 and IPv6, then the dry-run above.
- How to distinguish code, dependency, data, and capacity failures: if the
  cache answers and the dry-run shows a normal count, the cause was a transient
  fetch failure. Lix disables a whole substituter after one request exhausts
  `download-attempts`, and `fallback = true` then queues every missing path for
  a local build. Paths still being queried on the lower-priority caches
  (Cachix, numtide) are a symptom, not a second fault.
- Who owns the decision to continue, roll back, or stop: the operator.

### Mitigate and Recover
- Safe mitigation: cancel the deploy. Pre-build the closure as the trusted user
  with `nix build --no-link --fallback --option download-attempts 5
  .#darwinConfigurations.M-02877.system`, then rerun the deploy, which only has
  to activate.
- Rollback or forward-fix trigger: forward fix. `download-attempts` is 5 in
  `modules/M-02877/darwin.nix` so a single blip is retried instead of disabling
  the cache. The 20s stall timeout still bounds a bad NAR.
- Data repair/replay procedure: none. The store is content-addressed and a
  cancelled deploy leaves the active system unchanged.
- Verification required after recovery: `/etc/nix/nix.conf` shows
  `download-attempts = 5`, and the deploy log has no `is disabled` lines.

## Release and Migration Readiness
- [ ] Release artifact and schema versions are identified.
- [ ] A breaking change has an explicit migration trigger and agent instruction.
- [ ] Migration is idempotent and repeat-run behavior is tested.
- [ ] Backup, restore, rollback, and post-migration verification are documented.
- [ ] Rollout can be halted before the blast radius expands.

## Secrets Management
| Secret | Source | Rotation | Consumer |
|---|---|---|---|
| External service auth material | managed runtime configuration | periodic | runtime services |
| Artifact signing material | managed signing service/local secure store | periodic | release pipeline |

## Security Testing
| Test Type | Cadence | Tooling |
|---|---|---|
| SAST | each PR | language linters/scanners |
| Dependency scan | each PR + weekly | supply-chain tools |
| DAST/pentest | scheduled | external/internal |

## Trust-Boundary Inventory
| Boundary | Principal/Input | Authority Granted | Validation | Audit Evidence | Failure Default |
|---|---|---|---|---|---|
| User/agent -> entrypoint | | | | | deny/reject |
| Entrypoint -> core | | | | | deny/reject |
| Core -> persistence | | | | | fail closed/transaction rollback |
| Runtime -> external dependency | | | | | timeout/degrade |

## Agent and Automation Safety
- Prompt/configuration text is treated as untrusted input until evaluated by
  the repository's policy gate.
- Automation must not infer authorization, ownership, or a migration approval
  that is not present in the governed context.
- Sensitive artifacts, credentials, and untrusted attachments are not executed
  or imported as instructions.
- Every privileged mutation has an actor, scope, and durable evidence trail.

## Security Change Review
- [ ] New inputs and outputs are classified.
- [ ] Trust boundaries and privilege changes are documented.
- [ ] Abuse cases cover spoofing, tampering, disclosure, denial of service, and
  privilege escalation as applicable.
- [ ] Secret handling, redaction, retention, and deletion were re-checked.
- [ ] Supply-chain and provenance implications are recorded.

## Compliance and Audit
- Regulatory scope:
- Audit evidence location:
- Exception process:

## Pre-Promotion Security Checklist
- [ ] Threat model updated for changed surfaces.
- [ ] Auth/authz tests pass.
- [ ] Dependency vulnerability scan reviewed.
- [ ] No unresolved critical/high security findings.

<!-- decapod:codebase-attestation:start -->

## Codebase Attestation

- Repository signal fingerprint: `0e05719cad3ab88e6d446097561a1ff22afe40a70b25362f791f6f983727d72e`
- Significant implementation surfaces: `.beads/` (1 files), `.github/` (1 files), `README.md/` (1 files), `docs/` (2 files), `terraform/` (1 files)
- Refreshed from the current codebase by `decapod specs.refresh`
<!-- decapod:codebase-attestation:end -->
