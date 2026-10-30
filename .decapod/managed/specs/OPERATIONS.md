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
the machine. Commit a flake update and its fixes before or right after the
deploy that uses them. Before a deploy, `git status` in the checkout must be
clean, or the dirty files must be the change under review.

Each topgrade run does the same. Its "Flake inputs" step runs
`just update-darwin`, and its next step runs `just deploy-darwin` on the
updated lock. Generation 343 (2026-10-23, nixpkgs 5adc5083) came from such a
run. After a topgrade run changes `flake.lock`, commit the lock in its own PR
from a workspace, when the deploy succeeds.

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

pi does not use the chain. The den-owned `lego-claude` provider
(`modules/M-02877/token-toolchain.nix`) goes straight to the gateway's
`/anthropic` endpoint. That is the gateway's documented endpoint for pi, and
it caches like `/claude` in an A/B test. We measured the reason on 2026-10-14
from the gateway's request log:
- Headroom 0.40.0 in `cache` mode loses its prefix lineage when the previous
  request ended in a one-shot message. Signet's pi extension adds such a
  message to the first request of each prompt.
- Headroom then forwards the original bytes of turns that it compressed
  before. The provider writes the conversation to the cache again.
- One session lost about 945k cache-write tokens in this way, and up to 274k
  tokens for one prompt (headroomlabs-ai/headroom#4213). Headroom saved 0.6%
  of input tokens in the same period.
- A controlled A/B test in pi RPC mode showed the same difference.

Claude Code, omp and Caveman Code still use Headroom as their first hop
(`modules/agent-providers.nix`). pi sessions that started before the profile of
2026-10-14 18:19Z keep the old base URL, `127.0.0.1:18788`, until they restart.
Restart them before the deploy that deletes local-model-proxy. If you do not,
they get "connection refused". New sessions start on `lego-claude`.
`/model anthropic-proxy/...` also goes straight to the gateway.

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
  No model traffic uses it now.
- pi sends the key as the bearer and as `x-api-key`. The gateway accepts only
  the bearer. A `bin-v4.0.2` compat mount with `wire_dialect: anthropic`
  forwards the bearer and compresses Anthropic requests. It compressed a JSON
  and log tool result from 29,956 to 867 tokens. It does not compress prose:
  pi's markdown tool outputs, already trimmed by RTK and context-mode, came
  through unchanged, and the run cost the same as the direct one. So
  `lego-claude` stays direct, and Caveman works in pi through its extension.
- The empty `x-api-key` on the provider is load-bearing. The extension refuses
  to route a provider whose `x-api-key` is empty ("keep the provider direct").
  Each new session warns "Caveman: pass-through for lego-claude/..."; that is
  expected.
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

pi offers CodeGraph's one tool, `codegraph_explore`, to the model directly
(`exposure = "direct"`). With the default `codemode` exposure, the model made
0 calls in 60 sessions (den#63).

### Server auto-upgrade and human SSH keys (paphos, oracle)

paphos (daily `03:30` local, reboots `05:00`-`06:30`) and oracle (daily
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
Tang is up when paphos boots.

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

- Repository signal fingerprint: `b53a73f1940e652f8e72adc2ac674e8d5af9afd246434df408d0b26eb7df0a82`
- Significant implementation surfaces: `.beads/` (1 files), `.dagger/` (10 files), `.github/` (1 files), `README.md/` (1 files), `docs/` (2 files), `scripts/` (1 files), `terraform/` (1 files)
- Refreshed from the current codebase by `decapod rpc --op specs.refresh`
<!-- decapod:codebase-attestation:end -->
