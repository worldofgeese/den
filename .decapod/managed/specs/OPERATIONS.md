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

### Deploy only committed inputs (M-02877)

`just deploy-darwin` builds the working tree, including uncommitted edits.
Generation 341 (2026-10-16) was built from an uncommitted flake.lock update
(nixpkgs 319e4ceb and ten other inputs) with two build fixes, and `main`
lagged it for five days: a deploy from a clean `main` would have downgraded
the machine. Generation 343 (2026-10-23, nixpkgs 5adc5083) came the same way
from a topgrade run, whose "Flake inputs" step ran `just update-darwin`
before the deploy (den#60).

Since plan P6 three parts stop this:
- `scripts/deploy-freshness.sh`, the first step of `just deploy-darwin`,
  refuses a checkout with uncommitted edits to tracked files and lists them.
  To deploy such edits on purpose, run `DEN_DEPLOY_DIRTY=1 just deploy-darwin`.
- topgrade's first step, "Den pull", runs `git pull --ff-only origin main`.
  Its second step deploys. topgrade no longer updates `flake.lock`.
- The flake inputs change only through the nightly bump PR
  (`.github/workflows/bump.yml`, "Flake Input Updates" below). `just
  update-darwin` stays for a manual update in a workspace; its lock goes into
  a PR like any other change.

The checkout must also contain `origin/main`. Agents merge through PRs from
workspaces, and nobody pulls the main checkout, so it falls behind. On
2026-10-30 topgrade deployed a main checkout that did not have PRs #52, #64,
#65 and #66 (11 commits). The deploy reported success, and it took Chorus
back from 0.23.0 to 0.21.1 and removed the CodeGraph `exposure = "direct"`.
`scripts/deploy-freshness.sh`, the first step of `just deploy-darwin`, now
stops a deploy from a commit that does not contain `origin/main`, and lists
the missing commits. To recover, commit or stash the local edits, run
`git pull --ff-only`, and deploy again. To deploy an older commit on purpose,
set `DEN_DEPLOY_STALE=1`.

The same deploy also built five uncommitted edits, and their authors are not
known. Each was checked, then committed on 2026-10-30:
- `flake.lock`: the lock of that run's "Flake inputs" step. Nine root inputs
  are newer than on `main` and none is older (nixpkgs `e62746b0`, 2026-10-28).
  The servers no longer read it: they build with
  `--override-input nixpkgs github:NixOS/nixpkgs/nixos-unstable`, so the lock
  feeds M-02877 and CI.
- `secretspec.age`: only `LEGO_GATEWAY_API_KEY` changed. The new value got
  HTTP 200 from the gateway, the committed value got 401, and the
  last-known-good cache already held the new value. So it was a rotation. A
  checkout of the old file restores a revoked key.
- `mcp-agent-mail` is gone from `modules/overlays.nix`, from
  `modules/shared-devtools.nix`, and from the comment in `modules/checks.nix`,
  with the `fastmcp` test override that only it needed. No live agent
  configuration used it. Agents coordinate through pi-messenger.
- `programs.nushell.loadSessionVariables = true` in
  `modules/M-02877/dktaohan.nix`, so nushell gets the Home Manager session
  variables, for example `SIGNET_*`.
- `modules/paphos/hardware.nix` no longer sets `boot.initrd.systemd.enable`.
  nixos-unstable removed the scripted initrd, and the option now fails
  evaluation.

The two fixes from that update, both no-ops once upstream changes:
- Lix: `common-lix.nix` passes `-Dmimalloc=disabled`, which Lix 2.95.4's
  `meson.options` no longer has, so configure stops with 'Unknown option'.
  `modules/M-02877/darwin.nix` filters the flag out.
- atuin 18.23.0: its PTY end-to-end suites time out in the Darwin build
  sandbox. `modules/overlays.nix` skips checks on Darwin only.

### pr-reviewer (M-02877)
`modules/M-02877/pr-reviewer.nix` runs the PR review daemon as the launchd
agent `com.dktaohan.pr-reviewer`, from a pinned Nix build of upstream
`NicholaiVogel/pr-reviewer` carrying two local patches. The first sends git
HTTPS auth as Basic, not Bearer, which GitHub's git endpoint rejects. The
second is upstream PR NicholaiVogel/pr-reviewer#32, review rounds and stacked
PRs, described below. Drop each patch when the pin moves past its upstream
merge.

- **Review rounds.** Each posted review is one round. Round 1 is a full
  review. Rounds 2 and 3 to `max_review_cycles` (default 2) check earlier
  findings first. After the limit, new findings go into a "Follow-up notes
  (non-blocking)" section of the review body. They open no thread and do not
  request changes. Only a critical finding still posts inline and can block:
  it must be `blocking`, of a kind in `critical_finding_kinds` (default:
  security, secret_exposure, data_integrity, correctness), carry an
  `evidence_note`, and sit on an added or removed line. A finding whose
  thread is still open is not posted again. When no blocking finding is
  open, the bot dismisses its own earlier `REQUEST_CHANGES`, because it never
  approves. A fix made in another file than the finding's (regenerated code,
  say) leaves the finding open: resolve its thread, and within 2 minutes the
  daemon records that and dismisses the change request, with no new review.
  The settings live in `[defaults]` of the runtime config.toml, and
  a repo can override them in `[repos.review_policy]`. Set
  `max_review_cycles = 0` for the old unlimited behavior.
- **Stacked PRs.** A push that leaves the PR's own change as it was is not
  reviewed again. That covers rebases, `gh stack` cascades, and the retarget
  after a parent merges; `pr-reviewer logs` shows them as
  `skipped:unchanged-diff`. For a PR based on another PR's branch, the prompt
  names the parent and the lower PRs' open findings, and a finding the
  parent already tracks is not repeated on the child. The automerge agent
  skips a PR whose base is not the repo's default branch: a stack is merged
  by hand from its bottom PR.

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

#### Automerge
The launchd agent `com.dktaohan.pr-reviewer-automerge`, defined in the same
file, merges a PR in the declared repos once pr-reviewer has reviewed its
current head. It merges as the gh identity, for two reasons. pr-reviewer never
approves, so GitHub auto-merge cannot key on its reviews. A merge made with a
workflow's `GITHUB_TOKEN` would not start the deploys on main.

The agent runs every 120 s. It merges a PR only when all of these hold:
- The PR is not a draft and has no `hold` or `do-not-merge` label.
- The author is worldofgeese, `app/github-actions` or `app/dependabot`.
  Teammates' PRs stay manual.
- `pr-reviewer queue list` has a completed `review_pr` task at the PR's
  current head SHA.
- No review thread is unresolved, and no review requests changes.
- Every check is complete with SUCCESS, SKIPPED or NEUTRAL. A PR with no
  checks also qualifies.
- Only the newest run of each check counts, grouped by check name and
  workflow. So a run that a concurrency group cancelled does not block once a
  newer run of the same check has superseded it, and the agent logs the
  entries it set aside. A cancelled run with no newer run still blocks. On
  2026-10-09, devrel-infra#330 was stuck behind a superseded `guides` run.
- GitHub reports the PR as MERGEABLE.
- The description has no "Before you merge" steps. The bump/signet PR asks for
  a restore drill first, so it stays manual, and so does any PR like it.

It runs `gh pr merge --match-head-commit <sha> --delete-branch`. The method
comes from the repo's settings, read once per pass: a merge commit where the
repo allows one, else squash, else rebase. LEGO/agentic-engineering-community
always squashes. On 2026-10-09 a fixed `--merge` failed on
LEGO/conference-dashboard, which allows only squash and rebase. A
failed merge is remembered per head SHA in `~/.local/state/pr-reviewer-automerge`
and is tried again only after a new push.

The log is `~/Library/Logs/pr-reviewer-automerge.log`. It gets one line per
merge, and one per change of skip reason. `PR_AUTOMERGE_DRY_RUN=1` runs a pass
that only logs. To hold a PR, label it `hold`. To stop merging, run
`launchctl bootout gui/$UID/com.dktaohan.pr-reviewer-automerge`.

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

A pi session that starts while a tunnel reconnects loses that service for the
session. A deploy restarts each tunnel agent whose script changed, and a
network change breaks every open session. The watchdog then needs up to two
minutes to see the break, and a new session about 80 seconds. On 2026-10-30 a
pi session started inside that window, after a deploy and a Wi-Fi change.
Signet's extension warned "SignetAI daemon not running", and chorus-pi
injected "Chorus: connection failed". Signet recovers by itself, because each
Signet tool checks the daemon again at each call. pi's MCP client does not
connect a server again after a failed first connection, so the session has no
Chorus tools. When `curl -fsS http://127.0.0.1:3870/api/health` answers, run
`/mcp reconnect chorus` in the session, or start a new session. chorus-pi's
check-in runs only at session start.
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
- Versions. Server, client and `chorus-pi` are all 0.23.0. The server moved
  to it in LEGO/devrel-infra#483 (2026-10-22), and devrel-infra pins it in
  `projects/aws-chorus/sst.config.ts`. v0.21.0 added private projects with a
  schema migration. devrel-infra's nightly release job opens a PR for each
  new server release. Keep `chorusVersion` in step with it: 0.21.1 is the
  first client release with pi's built-in MCP, so never downgrade the client
  to match an older server. 0.22.1 gives pi sub-agents their role-scoped
  Chorus tools again (Chorus#608) and makes the daemon retry a failed wake
  delivery (Chorus#609). 0.23.0 adds the submit gate (`CHORUS_SUBMIT_GATE`,
  INTERFACES.md).
- The Chorus CLI is an npm global (`~/.local/bin/chorus`), installed and pinned
  by activation because the package is the whole Chorus server app. The CLI is
  a `#!/usr/bin/env node` script and the activation PATH has no Node, so the
  version check runs it with Node on PATH. Until 2026-10-08 the check always
  failed, and every switch reinstalled all 795 packages.
- Shells and `chorus-pi-daemon` get the key from `chorus-api-key`: secretspec,
  else the last-known-good cache. See ARCHITECTURE.md, Chorus Key Lookup.

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

The team pool needs the `SIGNET_*` session variables in every shell. A herdr
pane starts with the herdr server's environment, which is as old as the
server, `__HM_SESS_VARS_SOURCED` included, so Home Manager's source-once guard
skipped every variable added since. Restarting WezTerm does not help, because
herdr keeps its server. On 2026-10-08 the server dated from 2026-09-30, its
panes had no `SIGNET_*`, and pi fell back to the personal daemon as agent
`default`. `programs.zsh.envExtra` (dktaohan.nix) now loads
`hm-session-vars.sh` once per `HERDR_PANE_ID`. A pi started before that keeps
its old environment: start it again in a new pane.

The personal daemon has run `ghcr.io/signet-ai/signet:0.238.0` since
2026-10-30 (before: 0.237.9 from 2026-10-08, and 0.232.1). The
`distrobox create` pin in darwin.nix is read only when the container is
created; it had stayed at 0.214.27 while the container moved on. The
in-container auto-update fails (`manifest_invalid` for linux-arm64), so to
upgrade, first deploy the new pin. Then:
1. Boot `com.dktaohan.signet-container` out. With the agent loaded, KeepAlive
   would recreate a removed container from the deployed pin.
2. Run `podman rm -f signet`. A stopped container does not stay stopped: the
   exported `signet` command starts it through distrobox-enter, and on
   2026-10-30 a call started it 1 s after `podman stop`. The data stays in
   `~/.agents`.
3. Clone `~/.agents` while no container runs:
   `cp -cR ~/.agents ~/.local/state/agents-backup-<date>`. It is about 7 GB
   and takes about 2 to 5 minutes. The 2026-10-30 copy is
   `~/.local/state/agents-backup-20261030b`, and the 2026-10-08 copy is
   `~/.agents.bak-signet-0.232.1-20261008`.
4. Bootstrap the agent again. It creates the container from the deployed pin.
   The first enter runs distrobox-init, and the daemon answered on 3850 after
   160 s on 2026-10-30.

On 2026-10-30 launchd had started the agent 277 times since its last load,
about every 10 s, and each run ended with "Another daemon instance is already
running". The daemon that
held the lock belonged to an earlier job. When launchd stops a job, it ends
the host's distrobox-enter, and the daemon in the container lives on. So the
script now stops the container when 3850 answers before the job starts its
daemon. Each run of that loop also ran `podman info`, and one failed call
stopped and started the VM. The script now retries `podman info` for 30 s
before a VM cycle (den#59).

The agent carries `AbandonProcessGroup`. When its script has started the
podman VM, vfkit and gvproxy keep the job's process group. On 2026-10-08,
without that key, the bootout in step 1 stopped the VM, and the Gas City
container with it.

Activation snippets run with Home Manager's activation PATH only: bash,
coreutils, diffutils, findutils, gettext, grep, sed, jq and ncurses. Neither
`/usr/bin` nor the user profile is on it, so `awk` and every other tool must be
named by store path. The first deploy of the pi integrations (den#27) stopped at
`awk: command not found` because the snippets were tested with a login shell's
PATH. Test a new snippet with `env -i PATH=<the PATH line from the generated
activate script> bash`.

pi's Signet extension is installed once by hand with `signet connect pi`
(it writes `~/.pi/agent/extensions/signet-pi.js`, which Signet owns). The
host `signet` is exported from the personal container, so that command writes
the container release's extension. Run it again after each container upgrade.
On 2026-10-08 that brought in the fix for Signet-AI/signetai#2077: prompt-submit
no longer blocks input. The previous file is in
`~/.local/state/signet-pi-backup/`.

The tunnel also depends on AWS credentials from the LEGO credential process,
which gets them through the Azure CLI. On 2026-10-06 ECS replaced the Signet
task at 16:14 while that Azure call timed out, so the tunnel could not resolve
the new task and team Signet was unreachable for about 15 minutes. It recovered
without intervention once `az` answered again. If the tunnel log shows sessions
ending and none starting, run `AWS_PROFILE=bts-devrel aws sts
get-caller-identity` before anything else.

### Token proxy chain (M-02877)

One launchd agent runs Headroom in an Apple `container` image on the
`proxy-chain` network, at `127.0.0.1:18787`. Headroom forwards to the LEGO
gateway's `/claude` endpoint. `com.headroom.watchdog` probes Headroom's
`/readyz` every minute and recovers a wedged container. Logs:
`/tmp/{headroom,headroom-watchdog}.{log,err}`.

We deleted local-model-proxy and Phoenix on 2026-10-14. local-model-proxy
forwarded each request byte for byte. It only counted tokens and sent traces
to Phoenix. The gateway records the same data with billed costs (see "Measure
the chain"). local-model-proxy kept Headroom's container IP from its own start,
so it returned 502 after each Headroom restart. The watchdog recycled it 30
times. If the two containers still run after the deploy, stop them with
`container stop local-model-proxy phoenix`.

The chain was down on 2026-10-06 for two independent reasons:
- Every start pulled `:latest` first and ran the container only if the pull
  succeeded. One pull hung for over 21 minutes while the image was already
  cached. Pulls are now bounded at 300 s, and a cached image starts when the
  pull fails or times out.
- The new Headroom image refuses to bind `0.0.0.0` without a proxy token, and
  it exited at start. A token collides with the gateway bearer that the
  harnesses already send. So every host publishes the port on loopback only
  and sets `HEADROOM_ALLOW_UNAUTHENTICATED_BIND` (`gateway.json` holds the
  reasoning). mahakala's Guix config reads the same value.

The watchdog matches its process with the exact container name
(`--uuid headroom`). A substring match killed a test container named
`headroom-test` on 2026-10-06.

Since 2026-11-01 pi uses the chain too, with Caveman's proxy in front. The
den-owned `lego-claude` provider (`modules/M-02877/token-toolchain.nix`) sends
each request to Caveman's `lego-claude` compat mount (`127.0.0.1:8787`). Caveman
forwards it to Headroom, and Headroom to the gateway's `/claude` endpoint. See
"pi through the chain" below.

From 2026-10-14 to 2026-11-01, pi went straight to the gateway's `/anthropic`
endpoint. That is the gateway's documented endpoint for pi, and it caches like
`/claude` in an A/B test. We measured the reason on 2026-10-14 from the
gateway's request log:
- Headroom 0.40.0 in `cache` mode loses its prefix lineage when the previous
  request ended in a one-shot message. Signet's pi extension adds such a
  message to the first request of each prompt.
- Headroom then forwards the original bytes of turns that it compressed
  before. The provider writes the conversation to the cache again.
- One session lost about 945k cache-write tokens in this way, and up to 274k
  tokens for one prompt (headroomlabs-ai/headroom#4213). Headroom saved 0.6%
  of input tokens in the same period.
- A controlled A/B test in pi RPC mode showed the same difference.

Headroom 0.41.0 fixed that (#4213). The A/B runs of 2026-10-23 and
2026-11-01 keep the cache through Headroom. Claude Code, omp and Caveman Code
use Headroom as their first hop (`modules/agent-providers.nix`). A running pi
session keeps the provider it started with, so a pi session from before the
deploy stays direct until it restarts. `/model lego-claude-direct/...` goes
straight to the gateway (see "pi through the chain").

#### Prompt cache

Cache writes are the largest cost. In the 7 days to 2026-10-14, the gateway's
`/usage` for all visible accounts shows these parts of the estimated cost:
cache writes 59%, cache reads 27%, output 13% and input 1%. An Opus 5.5 cache
read costs 5% of an input token. A cache write costs 25 times a read. So a
change that breaks the prompt cache costs more than any compression saves.

`gateway.json` gives pi's models a `cost` block and `promptCache.short = 300`.
With both, pi keeps the cache warm during a long tool run and shows the
session cost. `cacheWarming` stays at its default, `streaming`. We measured
this on 2026-10-14 with a 330 s tool call on Sonnet 5.5:
- With the two keys, pi sent one `cache_warm` request. The next request read
  49,779 tokens from the cache and wrote 132.
- Without them, the cache expired. The next request wrote 25,621 tokens.

`cacheWarming: "idle"` also warms the cache between prompts. We do not set it,
because pi does not document when it stops for an abandoned session.

#### Measure the chain

The gateway's app API at `https://app.genai.thelegogroup.com` records every
request with billed usage. It takes an Entra token, not the gateway key:
`az account get-access-token --scope api://917243ee-d114-44a7-bb10-09ae72bf100d/.default`.
- `GET /usage?start=…&end=…&interval=day&group_by=model` returns token and
  cost buckets, with cache reads and writes. `interval=5m` and
  `group_by=account` also work.
- `GET /logs?window=last_24h&account=<id>` lists sessions.
  `GET /logs/<session>` lists the turns and their usage.
- `GET /logs/<session>/requests/<request>` returns the stored request body.

The gateway starts a new session when a request does not extend the previous
one, so one pi session can show as several sessions. The stored `tools` list
of a request holds only the tools that the conversation called. pi's session
files record the usage and cost of each request.

#### Caveman

Caveman runs at full strength in pi, without its cloud features. We install it
by hand:
1. Run `npm install -g @caveman-ai/cli@4.0.1`, then `caveman setup --install`.
2. Run `caveman setup --yes --agents none --skip routing`. This writes the
   module state to `~/.caveman/cloud.json`.
3. Run `caveman telemetry off`. Telemetry was on by default (opt-out) and sends
   command and token counts to Caveman. den also sets `DO_NOT_TRACK=1` for the
   proxy and for the hook CLI that pi starts.
4. Run `caveman on scripts`. This installs Caveman Blocks (0.1.0-rc.5) and its
   hooks in `~/.claude/settings.json` and `~/.codex/hooks.json`. Codex asks
   once: open `/hooks` in Codex and approve the `caveman-blocks` hook.
5. Replace the seven binaries in `~/.caveman/bin` with the `bin-v4.0.2`
   release assets. CLI 4.0.1 installs `bin-v4.0.1`, whose native runtime
   answers nothing (JuliusBrussee/caveman#1279, #1366). Check each asset
   against `checksums.txt`, and check `checksums.txt` against the release's
   signature, before you install it.
6. Replace `dist/caveman-pi-extension.mjs` in the npm-installed CLI with the
   pi extension built from JuliusBrussee/caveman#1376 (`packages/pi-extension`,
   `npm run build`, `dist/index.mjs`). The released extension puts per-prompt
   context in the system prompt, so the provider re-writes its prompt cache at
   every prompt (#1364). Undo steps 5 and 6 when a CLI release ships
   `bin-v4.0.2` and #1376.
7. Restart the proxy with
   `launchctl kickstart -k gui/$UID/com.dktaohan.caveman-proxy`.

Do not use `--agents pi`. It writes `~/.pi/agent/extensions/caveman-native.js`,
and pi then loads the extension a second time beside den's shim.

The modules and pi, measured on 2026-10-15:
- `output`, `input`, `waste-fixes` and `browse` are on.
- `scripts` (Caveman Blocks) is on for Claude Code and Codex. Blocks has no pi
  harness yet (caveman-ai/blocks#11). Its Codex entry runs `--harness claude`,
  which we asked about in caveman-ai/blocks#12. Blocks follows the Caveman
  telemetry decision in `cloud.json`, which is off since 2026-10-23.
- `routing` is off. Auto (`caveman-auto`) reaches only the Claude Code and
  OpenCode model pickers, not pi (JuliusBrussee/caveman#1286). It also needs a
  Caveman Cloud sign-in, and each routed request sends the latest prompt (up
  to 128 KiB), the prompt before it and the last reply to Caveman Cloud. That
  is a cloud feature, and we do not use cloud features.

What one pi session costs with Caveman, measured on 2026-10-23 (pi 1.4.0,
Claude Haiku 4.5, the same 8 prompts per run, `~/.cache/chain-test/cave-max.sh`):

| Run | Cache-write tokens | Cost |
|---|---:|---:|
| No Caveman extension | 38,685 | $0.107 |
| Released extension, `bin-v4.0.2` runtime | 131,658 | $0.234 |
| Extension from #1376, `bin-v4.0.2` runtime | 35,975 | $0.112 |
| No extension, requests through a `bin-v4.0.2` compat mount | 40,089 | $0.112 |

Caveman behaviours that shape this design:
- Without `caveman.yaml`, Caveman sends Anthropic-format requests to
  `api.anthropic.com`. That hands the LEGO gateway key to Anthropic (measured
  2026-10-06). The file sets the gateway's `/claude` endpoint as the upstream.
  No model traffic uses it.
- pi sends the key as the bearer and as `x-api-key`. The gateway accepts only
  the bearer. A `bin-v4.0.2` compat mount with `wire_dialect: anthropic`
  forwards the bearer and compresses Anthropic requests. It compressed a JSON
  and log tool result from 29,956 to 867 tokens. It does not compress prose:
  pi's markdown tool outputs, already trimmed by RTK and context-mode, come
  through unchanged. Since 2026-11-01, `lego-claude` uses the `lego-claude`
  mount (see "pi through the chain").
- The provider's empty `x-api-key` keeps the key out of that header. Each new
  session prints "Caveman: pass-through for lego-claude/...". That is
  expected: the provider URL is already the proxy.
- In the long-lived `~/.caveman`, the `bin-v4.0.2` runtime under launchd can
  answer every `native.sock` request with an empty reply while the proxy uses
  50% to 85% CPU. A fresh home answers. The extension then fails open: no
  shrinking and no runtime context, and no error. We reported it on
  JuliusBrussee/caveman#1279. To check: send `session.start` on
  `~/.caveman/run/native.sock` and expect a JSON reply.
- Since 4.0.1, the extension does not shrink tool output in a session that
  cannot call `caveman_retrieve` (#1211). So the den-generated `techwriter`
  agent does not name `caveman_retrieve` in its `tools:`.

The shim (`~/.pi/agent/extensions/caveman.js`) only loads the npm-installed
extension (`dist/caveman-pi-extension.mjs`).

#### Headroom 0.41.0 fixes

Headroom 0.41.0 (released 2026-10-14, `:latest` since then) carries the fixes
for the two bugs that `gateway.json` worked around with 0.40.0. So the
container runs without `HEADROOM_NO_MEMORY_TOOLS` and `HEADROOM_EXCLUDE_TOOLS`
(den#41):
- headroomlabs-ai/headroom#4009, fix #4013. When the model calls a Headroom
  memory tool and a client tool in the same turn, Headroom gives the turn back
  to the client. It no longer sends a continuation that the provider rejects
  with a 400. Headroom injects its `memory_save` and `memory_search` tools
  again.
- #4010, fix #4014. `caveman_retrieve` is in Headroom's built-in
  `DEFAULT_EXCLUDE_TOOLS` and `DEFAULT_VERBATIM_EXCLUDE_TOOLS`. Its output
  passes through byte for byte. The old `HEADROOM_EXCLUDE_TOOLS` entry only
  stopped the lossy step, so indented JSON still arrived minified.

We checked both on 2026-10-23 in the running 0.41.0 image: the two sets in
`headroom.config`, and the guard in `headroom/proxy/handlers/anthropic.py`.
Kompress still deletes keywords from a fenced code block inside a mixed tool
result (headroomlabs-ai/headroom#4214). A change to Headroom's settings
restarts the Headroom container, which is in the model path of the other
harnesses. Apply it from a plain terminal.

When you test by hand, use container names that do not start with `headroom`,
and spare loopback ports (28787 and 28788 were used). Verify Headroom with
`curl -s 127.0.0.1:18787/readyz`. Then send a `/v1/messages` call with the
gateway key as `Authorization: Bearer`. The gateway rejects the key when it
arrives only as `x-api-key`.

#### Headroom state and CodeGraph in pi

The Headroom container keeps all of its state on the `headroom-data` volume:
`HEADROOM_WORKSPACE_DIR=/data` and `HEADROOM_MEMORY_DB_PATH=/data/memory.db`.
Before 2026-10-23 only `proxy_savings.json` was on the volume. The memory,
`--learn`, the CCR store and the `headroom savings` ledger reset at each
restart (den#62, headroomlabs-ai/headroom#4443). `HEADROOM_STORE_URL` is gone,
because the proxy never read it.

Since 2026-11-01 the HuggingFace model cache is on the volume too:
`HF_HOME=/data/huggingface` and `HF_HUB_DISABLE_XET=1`. Headroom downloads its
models (Kompress int8 ONNX 261 MB, MiniLM ONNX 86 MB) before it listens. With
the cache in the container layer, every restart downloaded them again. On
2026-11-01 the Mac's Wi-Fi gave 0.1 MB/s, and the xet transfer stayed at
0 bytes. So each new container was still downloading when the watchdog
recycled it, every 10 minutes, and pi, Claude Code and omp had no Headroom for
hours. On the volume the models download once, and an interrupted download
resumes over plain HTTPS.

mahakala's Guix Home config sets the same variables
(`guix/home-configuration.scm`): `HEADROOM_WORKSPACE_DIR`,
`HEADROOM_MEMORY_DB_PATH`, `HF_HOME` and `HF_HUB_DISABLE_XET`. Until 2026-11-01 it still read the
`storeUrl` and `savingsPath` keys, which left `gateway.json` on 2026-10-23, so
`guix home reconfigure` failed on the missing key, and mahakala ran its Guix
Home generation of 2026-09-25. In that generation, shepherd started headroom
at login before the network was up. Every `podman run --pull always` exited
125, and shepherd disabled the service for 45 hours. The config now uses
`--pull newer`, which runs the local image when the registry cannot be reached.

To keep the watchdog from recycling a Headroom that is still downloading, write
a future time into its cooldown file:
`echo $(( $(date +%s) + 7200 )) > /tmp/headroom-watchdog.cooldown`. The
watchdog acts again 10 minutes after that time.

pi offers CodeGraph's one tool, `codegraph_explore`, to the model directly
(`exposure = "direct"`). With the default `codemode` exposure, the model made
0 calls in 60 sessions (den#63).

#### pi through the chain

pi's `lego-claude` provider (`agentProviders.pi` in
`modules/M-02877/token-toolchain.nix`) is set up like this:
- `baseUrl` is `http://127.0.0.1:8787/compat/lego-claude`, a compat mount of
  Caveman's proxy.
- The mount (`~/.caveman/caveman.yaml`) sends requests to Headroom
  (`base_url: http://127.0.0.1:18787`) with `wire_dialect: anthropic`. A compat
  mount keeps the inbound bearer, which is the only credential the gateway
  accepts (caveman#1215).
- Caveman's SSRF guard blocks loopback upstreams, so the proxy runs with
  `CAVE_SSRF_ALLOWLIST=127.0.0.1` (caveman#841). Without it, every request gets
  a bare 502 `cave_upstream_unavailable`, and the log has no line for it
  (caveman#1440).
- The provider sends `x-headroom-cwd: ${PWD}`, which pi expands per request.
  Headroom does not find pi's working directory itself (headroom#4442), and
  without a project it still adds its memory tools (9,838 bytes) to each
  request. The mount forwards only standard headers, so its
  `forward_headers` names this one.
- The Caveman extension sees that the provider URL is the proxy itself and
  does not route the provider again. Each new session prints "Caveman:
  pass-through for lego-claude/... points at the Caveman proxy itself". That
  is expected. Tool-output shrinking and `caveman_retrieve` still work.

Both hops are now in pi's model path. If Caveman or Headroom is down, pi's
requests fail with a 502 `cave_upstream_unavailable`, and there is no fallback
to direct. launchd restarts Caveman, and `com.headroom.watchdog` recovers
Headroom. Restart either one from a plain terminal, never from a pi session.
To skip the proxies, use `lego-claude-direct`. den writes it next to
`lego-claude` in `~/.pi/agent/models.json` on every host: the same models, sent
straight to the gateway's `/anthropic` endpoint.

| To change | Direct | Through the proxies |
|---|---|---|
| The current session | `/model lego-claude-direct/<model id>` | `/model lego-claude/<model id>` |
| Every new session | the same pick, then Ctrl+S in the `/model` picker | the same pick, then Ctrl+S |
| One launch | `pi --provider lego-claude-direct` | `pi --provider lego-claude` |

Ctrl+S saves the pick as pi's default (`defaultProvider` and `defaultModel` in
`~/.pi/agent/settings.json`), and den keeps a saved default. Use the direct
provider while a hop is down; the old hand-made `anthropic-proxy` provider has
no `promptCache`, so pi does not keep its cache warm.

What we measured on 2026-11-01 with `~/.cache/chain-test/chain-ab.sh`: an
isolated pi agent dir with a one-shot stand-in for Signet, a private bin-v4.0.2
Caveman proxy on `:18797`, and a test Headroom 0.42.0 container on `:28787`.
pi 1.4.0, and every tool at its latest release:

| Session | Direct | Headroom | Caveman | Caveman, then Headroom |
|---|---:|---:|---:|---:|
| Haiku 4.5, 8 prompts, mean of 4 runs | $0.121 | $0.116 | $0.108 | $0.131 |
| Haiku 4.5, 16 prompts with long reads, 1 run | $0.420 | $0.417 | $0.387 | $0.371 |
| Opus 5.5, 16 prompts with long reads, 1 run | $1.657 | not run | not run | $1.693 |

- The cache holds through both hops. No request re-wrote the conversation,
  and the cache writes of a session track its number of requests.
- Opus 5.5 with thinking runs through both hops without an error.
- The run-to-run noise is large: the same 8 prompts took from 14 to 29
  requests. The chain's cost is within that noise of direct.
- Caveman's compat mount removed 0 tokens in these sessions. It compresses
  JSON and logs, not prose. Headroom removed about 200k tokens over 224
  requests, mostly from content that the cache already held.

#### billion-context (evaluated 2026-11-01, not installed)

billion-context (ranxianglei/billion-context, MIT) lets the model fold old
turns into summaries, through its own pi extension and loopback proxy. We
tested 0.1.210, 0.1.211 and the build of its PR #4898, and did not install it:
- On Opus 5.5 with thinking, one session failed after its third fold. Every
  later request got 400 "`thinking` or `redacted_thinking` blocks in the latest
  assistant message cannot be modified" (billion-context#4885). The fix, PR
  #4898, is not in a release. Two later fold sessions, on 0.1.211 and on the PR
  build, finished.
- Its tools join the request only from the second request of a session, so
  each session, and each subagent run, re-writes about 20k cache tokens once
  (billion-context#5459).
- Cost against direct: +31% (Haiku 4.5, 8 prompts, 4 runs), +13% (Haiku 4.5,
  16 prompts with long reads, 2 runs) and +25% (Opus 5.5, through the chain,
  no fold). In one Haiku run, the model answered 2 recall questions wrongly
  after a fold.
- Its subagent tools (`acp_delegate`) overlap chorus-pi's `subagent`.
  `"pi": {"subagents": false}` in `~/.config/billion-context/billion-context.json`
  turns them off.

Run `chain-ab.sh direct bili bilicavehr` again when a release includes #4898.
Declare it unpinned (`npm:billion-context`), like the other pi packages. Its
proxy then also updates it through pi between switches.

### Server auto-upgrade and human SSH keys (paphos, oracle)

paphos (daily `05:00` local, up to 20 minutes late, reboots `05:00`-`06:30`) and oracle (daily
`04:00` UTC, reboots `04:00`-`05:00`) run `nixos-upgrade.service` against the
published flake `github:worldofgeese/den`, not a local checkout. They build
whatever is on `main`, with one exception: nixpkgs. Each run passes
`--override-input nixpkgs github:NixOS/nixpkgs/nixos-unstable`, so a security
fix lands within a day of reaching nixos-unstable. Before, it waited for
someone to commit a flake.lock. In October 2026 the committed lock held both
servers on mid-October nixpkgs through the Black October fixes:

- Node 22.23.4, which carries Pangolin's Node2Shell fix on oracle.
- cacert 3.131.1, which removes the eMudhra root.
- Forgejo's security releases.

Every other input stays pinned by the committed lock. nixos-unstable advances
only after Hydra's NixOS tests pass. A run that fails to build leaves the
running system in place. paphos' hourly health check sends these Telegram
alerts:

| Alert | Sent when |
|---|---|
| `nixos-upgrade-failed` | The upgrade unit is in the failed state. |
| `reboot-pending-<n>d` | An installed kernel has not been booted for two days. |
| `nixpkgs-stale-<n>d` | The running system's nixpkgs (`BUILD_ID` in `/etc/os-release`) is 14 days old. |

The last two catch upgrades that stop landing without a failed unit. That is
how paphos ran kernel 7.0.3 for 175 days with 7.3 installed.

Unattended reboot on paphos: the LUKS root unlocks through Tang, which is
network-bound disk encryption. `boot.initrd.clevis` holds the passphrase
sealed to the Tang server on mother (`192.168.99.200:7500`). That server is a
root-owned container built from Fedora's `tang` package by
`/volume1/@local-sbin/tang/rebuild.sh`, and a weekly root cron job rebuilds
it. Its keys are in `/volume1/@tang-db`.

If paphos is off the home LAN, or mother does not answer, the initrd waits
for the passphrase over SSH as before: `ssh -p 2222 root@paphos`.

The sealed passphrase exists only on paphos, at
`/etc/secrets/initrd/root.jwe`, and in its initrd. It is never in this
repository. Create it once, and again after a Tang re-key or a passphrase
change, with `sudo /etc/secrets/initrd/enroll-tang.sh` on paphos. The script
verifies that the Tang round trip unlocks the disk before it keeps the file.
Without `root.jwe` the upgrade build fails and alerts as
`nixos-upgrade-failed`.

The reboot window opens after mother's Monday `04:00` DSM auto-update, so
Tang is up when paphos boots. The run starts inside the window because NixOS
checks the window when the build finishes. Outside it, the run skips the
reboot and, when the kernel changed, the switch too. Until 2026-10-30 paphos
started at `03:30`, so it skipped every reboot.

Firmware: paphos runs fwupd. `paphos-firmware-update` (daily `04:30`) applies
what LVFS offers, such as UEFI dbx updates. A capsule installs on the next
boot, so `paphos-firmware-reboot` (daily `06:00`, inside the window) reboots
when an update is pending (fwupd `UpdateState` 1 or 4), unless
`nixos-upgrade.service` is still running. mahakala applies LVFS firmware every
six hours through an mcron job in `guix/system.scm`; a laptop is often asleep
at night, and its capsules install at the next reboot. loving-kypris is not
managed by den: it runs the same fwupd check daily at `04:00` from local units,
and bootc (`bootc-fetch-apply-updates.timer`, daily `04:30`) applies its uCore
image updates.

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
rekey the agenix secrets for paphos. The same file pins mother's host key for
`paphos-forgejo-backup`. If mother's SSH host key changes, the backup fails
with "Host key verification failed" until its pin changes.

### mahakala desktop: Hyprland and the GPU driver (M-02877)

On mahakala (Guix System), Hyprland and Mesa both come from the Nix Home
Manager profile. At boot, the root shepherd one-shot `nix-opengl-driver` in
`guix/system.scm` points `/run/opengl-driver` at the `non-nixos-gpu` env of
the current HM generation (`targets.genericLinux.gpu` in
`modules/worldofgeese.nix`). Hyprland loads Mesa's `libgallium` into its own
process, using its own glibc. Mesa must therefore need a glibc no newer than
the one Hyprland was built against.

If those glibcs differ, Hyprland exits with
`MESA-LOADER: ... version GLIBC_2.4x not found` and `CBackend::create() failed`
in `~/.local/state/omarchy-session.log`, and GDM reports that as
"authentication error". This happened on 2026-11-01. HM generation 362 paired
a Hyprland built against glibc 2.42 with Mesa 26.2.5 built against glibc 2.44.
The failure only appeared after the next reboot, because only the boot service
re-points the driver link.

- **Check**: `$G/ld-linux-x86-64.so.2 --preload "$G/libc.so.6 $G/libm.so.6"
  --list <gpu-env>/lib/libgallium-*.so`, where `$G` is Hyprland's glibc
  `lib`. The output must contain no `not found` lines.
- **Hotfix** (lost on reboot): `sudo ln -sfT <older non-nixos-gpu>
  /run/opengl-driver`. Add a GC root for that env.
- **Fix**: deploy an HM generation whose Hyprland and Mesa share a glibc
  version, then reboot or re-point `/run/opengl-driver`.

`modules/omarchy.nix` replaces Omarchy's systemd-only calls in
`omarchy-system` (`uwsm stop`, `systemctl reboot`/`poweroff`,
`systemd-inhibit`, `systemd-run --user`) with `hyprctl dispatch exit`, elogind
`loginctl`/`elogind-inhibit`, and `setsid --fork`. The build fails if any
uncommented systemd call remains. Omarchy 4.5.0-rc2 merged the old
`omarchy-system-{logout,reboot,shutdown}` scripts into `omarchy-system`.
nixarchy replaces `enable-user-units.sh` with a no-op. The guard patches that
script only while it still calls `systemctl`.

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

## Flake Input Updates

The nightly bump (`scripts/bump-flake-inputs.sh`) rewrites this section. On 2026-11-01 it changed 57 nodes of `flake.lock`.

| Node | Before | After |
|---|---|---|
| `ai-mirror` | 929c9d1 (2026-09-22) | c4b69d0 (2026-10-30) |
| `aquamarine` | f31c47a (2026-09-17) | 52ea11f (2026-10-03) |
| `darwin` | bb0b90d (2026-10-23) | ff0e21a (2026-10-31) |
| `decapod` | 2939be8 (2026-10-22) | 3216d71 (2026-11-01) |
| `devshell` | (new) | 255a2b1 (2026-01-19) |
| `emacs-overlay` | dca11ca (2026-10-29) | 9000a9a (2026-10-31) |
| `ewm` | b175b96 (2026-09-28) | 21d3c95 (2026-10-29) |
| `flake-parts_4` | 8645992 (2025-10-20) | 250481a (2026-01-05) |
| `flake-parts_5` | (new) | 8645992 (2025-10-20) |
| `gliff` | (new) | 58c7424 (2026-10-24) |
| `helium` | c9f74b5 (2026-10-29) | 0a71a74 (2026-10-31) |
| `home-manager_5` | 1dc2d1f (2026-09-01) | 6407259 (2026-10-15) |
| `hypr-rdp` | 8744778 (2026-09-10) | (removed) |
| `hyprgraphics` | 7c895c4 (2026-08-11) | 80c7d00 (2026-10-03) |
| `hyprland` | 23118f9 (2026-09-22) | 3633316 (2026-10-16) |
| `hyprland-guiutils` | 4c30cf3 (2026-08-11) | 204f39d (2026-10-12) |
| `hyprland-protocols` | cc9a8fd (2026-09-15) | 4c27ba9 (2026-10-06) |
| `hyprtoolkit` | af515b6 (2026-08-05) | 2907e0d (2026-10-12) |
| `hyprutils` | a21e87b (2026-09-05) | 95983ee (2026-09-21) |
| `llm-agents` | 467c27c (2026-10-30) | e78ca7f (2026-11-01) |
| `mcp-nixarchy` | (new) | a3059f3 (2026-10-25) |
| `mcp-servers-nix` | 11fe241 (2026-09-11) | d1185e9 (2026-10-25) |
| `microvm` | fdfc182 (2026-09-04) | 4876e2a (2026-10-24) |
| `nix-doom-emacs-unstraightened` | 2b297e8 (2026-10-29) | 85c6081 (2026-10-31) |
| `nix-flatpak` | 4408189 (2026-01-09) | 7c7c173 (2026-10-10) |
| `nixarchy` | 864eeb0 (2026-09-28) | e2cafea (2026-11-01) |
| `nixarchy-devenv` | f482185 (2026-09-24) | e1c7180 (2026-10-20) |
| `nixarchy-distrobox` | 74d1337 (2026-09-24) | cfa684f (2026-10-20) |
| `nixarchy-flatsnap` | e9993a1 (2026-09-25) | e9532c3 (2026-10-20) |
| `nixarchy-ghtui` | 6d42838 (2026-09-24) | 3fb9c8d (2026-10-20) |
| `nixarchy-gliff-manager` | (new) | 5b868f6 (2026-10-20) |
| `nixarchy-gltui` | c8b79e6 (2026-09-24) | 8445d25 (2026-10-20) |
| `nixarchy-herdr` | 5bb2796 (2026-09-25) | affd985 (2026-10-20) |
| `nixarchy-hyprsettngs` | (new) | 367ca99 (2026-10-20) |
| `nixarchy-menu` | 2cce175 (2026-09-25) | cfb4fc1 (2026-10-20) |
| `nixarchy-microvm` | 27e5992 (2026-09-24) | ca0bc01 (2026-10-20) |
| `nixarchy-omatheme` | e62e88f (2026-09-28) | 51fb129 (2026-10-20) |
| `nixarchy-pkg` | 93add27 (2026-09-24) | b7786c2 (2026-10-20) |
| `nixarchy-plugin-browser` | b380ebb (2026-09-24) | 1f21a1b (2026-10-20) |
| `nixarchy-podman` | 73d4a68 (2026-09-24) | e1aaf12 (2026-10-20) |
| `nixarchy-voice` | 7c51dfb (2026-09-27) | 0231774 (2026-10-20) |
| `nixi` | 4e6c1b5 (2026-09-24) | 39af9e3 (2026-10-23) |
| `nixi-companion` | (new) | 09af56c (2026-10-23) |
| `nixpkgs` | e62746b (2026-10-28) | 885ba4d (2026-10-30) |
| `nixpkgs-lib_2` | a73b9c7 (2025-08-10) | 2075416 (2025-12-14) |
| `nixpkgs-lib_3` | (new) | a73b9c7 (2025-08-10) |
| `nixpkgs_2` | e554fab (2026-09-17) | 7fd4004 (2026-10-11) |
| `nixpkgs_3` | e158d9e (2026-09-26) | 1c89083 (2026-10-30) |
| `nixpkgs_4` | e62746b (2026-10-28) | d357a2b (2026-11-01) |
| `omarchroma` | 5d05f16 (2026-09-24) | 7048180 (2026-09-28) |
| `omarchy` | c668141 (2026-09-15) | 5978d93 (2026-10-27) |
| `pre-commit-hooks` | 59f4ca0 (2026-09-15) | 1ba1dbf (2026-10-13) |
| `rust-overlay` | 96a0986 (2026-10-30) | c85ccd3 (2026-11-01) |
| `sops-nix` | 5efb5a6 (2026-09-27) | 442449f (2026-10-24) |
| `spectrum` | a7762d6 (2026-08-03) | 77d2389 (2026-08-06) |
| `xdph` | ba31964 (2026-08-29) | 0121b2e (2026-10-12) |
| `zen-browser` | ec2c94c (2026-09-06) | 4434539 (2026-10-27) |

## Limited NAS Recovery Evidence

The procedure is in `scripts/fleet-maintenance/README.md`. Bead `home-manager-zym` records the private deployment evidence. The first checkpoint passed native Restic `check --read-data` and a byte-identical archive restore on 2026-11-01. Three restored SQLite databases passed `PRAGMA quick_check`. The archive also contained all 14 PostgreSQL exports. These results do not prove a full NAS or application rebuild.

The organization recovery key has a separate copy in the Mac Keychain. The source receipt, encrypted snapshot, restore result, and key reference must describe the same repository. The operator deleted both owned NAS runs and the plaintext archive on loving-kypris after the restore passed. The encrypted snapshot remains.

The new recurring job stays disabled until each run prepares fresh source data and checks its age and identity. Existing backup jobs and native updaters remain unchanged. A successful timer exit alone does not prove current firmware or successful application after a reboot.

Swamp authentication passed with the supplied API key through `SWAMP_API_KEY_FILE`. The private key file has mode `0600`. Telemetry is disabled in the private Swamp profile. The CLI installation does not prove a scheduled service, a safe repair procedure, or an unattended firmware update. SRM recovery and an independent observer still need proof. The installed loving-kypris BIOS used the user's manual F7 selection, not an autonomous flash.

The checkpoint caller passes offline tests for stale receipts, changed bindings, old success results, partial backups, bounded copies, and restored artifacts. Its simulated full run requires restoration before cleanup. Two live runs passed on 2026-11-01. A direct run made snapshot `88b1a016`. A run through the Swamp service made `02562414`. Each run restored a byte-identical archive and passed all its archive checks. The Zerobyte API has no per-repository key scopes. The user approved a dedicated key without expiry and with organization-wide access. The user timer `mother-recovery-checkpoint.timer` runs the workflow at 00:30 UTC each day. `paphos-health-check` reports `mother-checkpoint-stale-Nh` or `mother-checkpoint-never` when the heartbeat from loving-kypris stops.

## Deploy Report and loving-kypris Liveness

`scripts/deploy-report.py` is plan step P8. The launchd agent `com.dktaohan.den-deploy-report` on M-02877 runs it at 08:15 each day. For paphos, oracle and M-02877 it reads the den commit in `/etc/den-revision` and the nixpkgs revision. `modules/deploy-revision.nix` writes that file with three lines: the flake revision, its narHash, and its lastModified time. paphos and oracle rebuild with `--override-input nixpkgs`, and Nix then drops `self.rev`. The report then finds the main commit whose commit time is lastModified, and confirms it by its narHash. The report asks GitHub how many commits of main the deployed commit lacks. It keeps one open issue with the label `deploy-report` for each failing step: `unreachable`, `upgrade-failed`, `den-revision-unknown`, `den-behind-main` (older than 36 hours), `nixpkgs-stale` (14 days) or `reboot-pending` (2 days). A later report that sees the step pass closes its issue. An unreachable host closes nothing. The issue shepherd of plan P7 must not close these issues. mahakala and pixel-fold record no den commit, so the report does not judge them.

`paphos-loving-kypris-liveness` samples loving-kypris every 2 minutes from paphos, as two targets: the host and Home Assistant. A target that fails for 10 minutes without a break sends one Telegram alert. The alert repeats every 2 hours while the target stays down. The first passing sample sends a recovery message. The check only reports and never power-cycles. It checks that Telegram accepts each message. A failed alert or recovery message is sent again at the next sample, and the unit fails until delivery succeeds. `paphos-loving-kypris-liveness-notify-test` sends one TEST message to prove the path. The firmware job on paphos now fails on every `fwupdmgr` exit code except 0 and 2 (nothing to do), and `paphos-health-check` reports `firmware-update-failed`.

<!-- decapod:codebase-attestation:start -->

## Codebase Attestation

- Repository signal fingerprint: `81ef68cb3c1bd45e2f3856081dc42db6c284037a02cf4c64374aff65bc1965bd`
- Significant implementation surfaces: `.beads/` (1 files), `.dagger/` (12 files), `.github/` (5 files), `README.md/` (1 files), `docs/` (2 files), `scripts/` (8 files), `terraform/` (1 files)
- Refreshed from the current codebase by `decapod rpc --op specs.refresh`
<!-- decapod:codebase-attestation:end -->
