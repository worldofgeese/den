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

Team Signet, Chorus and tfh have no load balancer or DNS name. Each is reached
only through an IAM-authenticated Systems Manager tunnel, so each has a
KeepAlive launchd agent. All three come from `mkSsmTunnel` in
`modules/M-02877/darwin.nix` and log to `~/.local/state/<name>.log`:

| agent | local URL | Session document | probe |
|---|---|---|---|
| `signet-team-tunnel` | `http://127.0.0.1:3860` | `Signet-production-Daemon` | `/health/ready`, needs a 2xx |
| `chorus-team-tunnel` | `http://127.0.0.1:3870` (MCP at `/api/mcp`) | `Chorus-production-App` | `/api/health`, needs a 2xx |
| `tfh-tunnel` | `http://127.0.0.1:3880` | `Tfh-production-App` | `/healthz`, any HTTP status |

Chorus and tfh moved there in LEGO/devrel-infra#279 and #280 (2026-10-07). Both
had internet-facing ALBs that admitted `0.0.0.0/0`; the `*.devrel.internal.lego`
names hid them but did not protect them, and Chorus's served the login page and
MCP API from off the LEGO network. Chorus's `NEXTAUTH_URL` is
`http://127.0.0.1:3870`, so its web login works only on that port. tfh's probe
accepts any status because every tfh route that serves content reads state from
S3 and takes 3 to 17 seconds; `/healthz` answers 404 at once. Port 3890 belongs
to FastHawk's local `ci:signet` dev service (devrel-infra#277).

Each tunnel agent is also a watchdog. It requests its probe path
through the tunnel every minute; after two misses in a row it
ends the SSM session and launchd reconnects to the current task. On
2026-10-06 a session stayed up and kept the port bound while every request
through it hung, so agents lost team memory without any error until the agent
was restarted by hand.
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
- Versions. Server, client and `chorus-pi` are all 0.21.1. The server moved
  from v0.20.0 in LEGO/devrel-infra#291 (2026-10-07); v0.21.0 added private
  projects with a schema migration. devrel-infra's nightly release job now
  opens a PR for each new server release. Keep `chorusVersion` in step with
  it: 0.21.1 is the first client release with pi's built-in MCP, so never
  downgrade the client to match an older server.
- The Chorus CLI is an npm global (`~/.local/bin/chorus`), installed and pinned
  by activation because the package is the whole Chorus server app.

Lessons from the first deploy (2026-10-06):
- pi 0.99.2 from llm-agents shipped without its codemode worker
  (numtide/llm-agents.nix#10128), so every codemode MCP call failed and chorus
  tools were unreachable. llm-agents after d47e048 (pi 1.0.4) embeds it; the
  flake.lock that topgrade produced is committed with that fix.
- The shell's Chorus key lookup ran `secretspec get` without `-f`, so it only
  worked in shells started inside this repo. It now names the project file.
- The daemon's browse root defaulted to `$HOME`, listing every directory name
  under it to the team server; it is now `~/projects`, like the served set.
- topgrade's deploy can fail on a flaky upstream test while it builds what
  Hydra has not cached (python3.14-fastmcp 3.4.7,
  `test_ping_task_cancelled_on_disconnect`). Rebuild that derivation once
  before suspecting the configuration.

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

The tunnel also depends on AWS credentials from the LEGO credential process,
which gets them through the Azure CLI. On 2026-10-06 ECS replaced the Signet
task at 16:14 while that Azure call timed out, so the tunnel could not resolve
the new task and team Signet was unreachable for about 15 minutes. It recovered
without intervention once `az` answered again. If the tunnel log shows sessions
ending and none starting, run `AWS_PROFILE=bts-devrel aws sts
get-caller-identity` before anything else.

### Token proxy chain (M-02877)

Three launchd agents run Apple `container` images on the `proxy-chain`
network, in the order a request passes them: local-model-proxy
(`127.0.0.1:18788`), Headroom (`127.0.0.1:18787`) and the LEGO gateway's
`/claude` endpoint. Phoenix (`127.0.0.1:16006`) receives local-model-proxy's
traces. `com.headroom.watchdog` probes Headroom's `/readyz` every minute.
Logs: `/tmp/{headroom,local-model-proxy,phoenix,headroom-watchdog}.{log,err}`.

The chain was down on 2026-10-06 for two independent reasons:
- Every start pulled `:latest` first and ran the container only if the pull
  succeeded. One pull hung for over 21 minutes while the image was already
  cached. Pulls are now bounded at 300 s, and a cached image starts when the
  pull fails or times out.
- The new Headroom image refuses to bind `0.0.0.0` without a proxy token and
  exited at start, so local-model-proxy looped on "could not resolve headroom
  container IP". A token would collide with the gateway bearer that the
  harnesses already send, so every host now publishes all three ports on
  loopback only and sets `HEADROOM_ALLOW_UNAUTHENTICATED_BIND`
  (`gateway.json` holds the reasoning). mahakala's Guix config reads the same
  value.

The watchdog's recovery now also recycles local-model-proxy, which otherwise
keeps the old Headroom IP and returns 502 for every request. Its process
matchers use the exact container name (`--uuid headroom`): a substring match
killed a test container named `headroom-test` on 2026-10-06.

pi uses the chain through the den-owned `lego-claude` provider
(`modules/M-02877/token-toolchain.nix`, after the community guide
`setup-token-saving-toolchain.md`). The provider's `baseUrl` is
local-model-proxy (`127.0.0.1:18788`), its real first hop, so model traffic
does not pass Caveman's proxy (`com.dktaohan.caveman-proxy`,
`127.0.0.1:8787`). That proxy still serves the Caveman pi extension's
tool-output shrinking, and its `~/.caveman/caveman.yaml` points its
Anthropic upstream at the same local-model-proxy. New sessions
start on `lego-claude`. Running sessions keep the provider they started
with, and `/model anthropic-proxy/...` goes straight to the gateway if the
chain is down. pi also loads RTK's and Caveman's extensions, ponytail and
context-mode (packages), Caveman's skills, and the context-mode, CodeGraph
and Headroom MCP servers.

Caveman behaviours that shape this design:
- Without `caveman.yaml`, Caveman sends Anthropic-format requests to
  `api.anthropic.com`, which would hand the LEGO gateway key to Anthropic
  (measured 2026-10-06).
- pi sends the key as the bearer and as `x-api-key`. Caveman's proxy
  forwards only `x-api-key` when both arrive, and the gateway accepts only
  the bearer, so a session routed through Caveman gets 401. An empty
  `x-api-key` made Caveman 1.x forward the bearer, which is why the provider
  used to point at Caveman itself (`/w/pi`), with a shim no-oping the
  extension's provider re-registration (which dropped `authHeader`).
- Caveman 2.x (`@caveman-ai/cli` 2.0.1, `bin-v2.0.2`, measured 2026-10-07)
  routes with `pi.setModel` and keeps `authHeader`, but refuses to route a
  provider whose `x-api-key` is empty ("keep the provider direct"), and its
  proxy still forwards `x-api-key` over the bearer (401 with both). So the
  provider goes direct, and the empty `x-api-key` stays: it is what keeps
  the extension from rerouting `lego-claude` into that 401. Each new session
  warns "Caveman: pass-through for lego-claude/...; no compression"; that is
  expected. Request compression through Caveman saved ~0 tokens before
  (201 tokens over 440 requests), and tool-output shrinking does not use
  this route. The shim (`~/.pi/agent/extensions/caveman.js`) now only loads
  the npm-installed extension.

Caveman's extension also shrinks tool output and returns a `ccr://` handle
for `caveman_retrieve`. Small outputs are shrunk too, which costs extra
retrieve turns. Watch for this before treating the setup as a net saving.
A handle is only recoverable while the session can call `caveman_retrieve`:
a pi subagent with its own `tools:` list replaces the active set, so the
den-generated `techwriter` agent names `caveman_retrieve` until Caveman ships
the fix for JuliusBrussee/caveman#1211 (PR #1196). Caveman binaries before
`bin-v1.1.7` also lose every handle (#1008, fixed by #1015); upgrade, then restart the proxy
from a plain terminal, never from an agent session that talks through it.

Headroom 0.40.0 runs with two workarounds from `gateway.json`:
`HEADROOM_NO_MEMORY_TOOLS=1` stops it injecting its memory tools, whose
server-side continuation 400s when the model also called a client tool in
the same turn (headroomlabs-ai/headroom#4009, fix #4013), while memory
storage and `--learn` stay on; `HEADROOM_EXCLUDE_TOOLS=caveman_retrieve`
stops it lossy-compressing recovered Caveman output (#4010, fix #4014).
Drop each once a Headroom release carries its fix. Changing them restarts
the Headroom container, which is in every session's model path, so apply
from a plain terminal.

When testing by hand, use container names that do not start with `headroom`,
and spare loopback ports (28787 and 28788 were used). Verify the chain with
`curl -s 127.0.0.1:18787/readyz` and `curl -s 127.0.0.1:18788/health`, then a
`/v1/messages` call that sends the gateway key as `Authorization: Bearer`. The
gateway rejects the key when it arrives only as `x-api-key`.

### Server auto-upgrade and human SSH keys (paphos, oracle)

paphos (`Wed 03:00`, no reboot) and oracle (daily `04:00`, reboot allowed) run
`nixos-upgrade.service` against the published flake `github:worldofgeese/den`,
not a local checkout. Whatever is on `main` is what they build. paphos'
health check sends a Telegram alert `nixos-upgrade-failed` while the unit is
in the failed state.

Invariant: evaluating a server configuration MUST NOT depend on mutable remote
content. A hash-pinned fetch of a URL whose content can change (for example
`https://github.com/worldofgeese.keys`) passes on any machine that still has
the old download cached. It then fails on a host as soon as that host's store
is garbage-collected. That makes the breakage silent locally and in CI.

Human SSH keys for `kypris@paphos` and `nixos@oracle` therefore come from
`modules/_worldofgeese.keys`, a vendored, byte-exact copy of the GitHub keys
endpoint. `modules/_github-ssh-keys.nix` returns that path. After adding or
removing a key on GitHub, refresh it with
`curl -fsSL https://github.com/worldofgeese.keys -o modules/_worldofgeese.keys`.
Review the diff and merge. The next upgrade applies it. To apply it now, run
`sudo systemctl start nixos-upgrade.service` on the host. If you forget the
refresh, the new key is not authorized yet. Upgrades keep working.

Incident 2026-10-07: both hosts' upgrades failed with `hash mismatch in file
downloaded from 'https://github.com/worldofgeese.keys'` after the
`google-pixel-fold` key was added on GitHub (2026-09-30). This was the second
occurrence. The first was fixed on 2026-09-09 by bumping the pin. Vendoring
the file removed the failure mode.

oracle `/boot` invariant: `/boot` is the OCI image's 249 MB ESP. Because it
is a separate partition, GRUB copies the kernel and initrd of every menu
generation into it (about 89 MB per aarch64 generation). install-grub copies
the new files before it deletes obsolete ones. So `/boot` must never hold
more than one generation's files after an install, which means
`boot.loader.grub.configurationLimit = 1`. The peak during an upgrade is then
two kernels (about 180 MB). The tradeoff: GRUB offers no older generation. To
keep fallback entries, mount the ESP at `/boot/efi` instead so that GRUB
reads kernels from the store. That migration needs a supervised reboot.

Incident, oracle part: oracle's last successful upgrade was 2026-09-24. From
2026-09-25 the copy of kernel 6.18.53 failed with "No space left on device".
Each failed attempt left a partial `*.tmp` copy in `/boot/kernels`, and nothing
cleans those up, so every later upgrade failed too. From 2026-10-02 the keys
hash mismatch masked this. Nothing alerted on oracle's failures for 13 days.
At the time, only paphos' own `nixos-upgrade.service` was monitored, by the
paphos health check, which pinged oracle only for relay reachability.

Monitoring: both servers' upgrade failures now alert through the same
Telegram bot. paphos' hourly `paphos-health-check` sends
`nixos-upgrade-failed`. paphos' hourly `paphos-oracle-relay-check` logs in
as `upgrade-status@oracle`, which can only run the forced command
`systemctl is-failed nixos-upgrade.service`, and sends
`oracle-nixos-upgrade-failed`. If the probe gets any unexpected answer
(unreachable, auth failure, or a changed host key) it sends
`oracle-nixos-upgrade-status-unavailable`, so the probe cannot silently go
blind. The check identifies itself with paphos' host key, and oracle's host
key is pinned in paphos' `known_hosts`. Both keys are defined once in
`modules/_host-keys.nix`. If either host is reinstalled, update that file and
rekey the agenix secrets for paphos.

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
