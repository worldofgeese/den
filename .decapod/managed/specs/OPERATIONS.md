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

Two deploys must not overlap. On 2026-11-05 agents agreed by chat who would run
the M-02877 switch, and nothing in the tooling stopped a second one. `just
deploy-darwin` now holds `/tmp/den-darwin-switch.lock` (`/usr/bin/lockf -k -t
0`) from the start of `scripts/cask-app-preflight.sh` through the end of
`darwin-rebuild switch`. A second deploy fails at once with exit 75 and `error:
another switch is running`; `pgrep -fl 'darwin-rebuild switch'` shows the
holder. The lock wraps `sh -c`, so `sudo` stays the direct command and the
sudoers rule `darwin-rebuild switch *` still matches.

### Decapod store copies
All agents on M-02877 share one Decapod store, `.decapod/data/decapod.db` in
the main checkout. Decapod moves forward with no hold: the nightly bump moves
the `decapod` flake input, and topgrade deploys it. A new release can migrate
the store at its first command. So `scripts/decapod-deploy-backup.sh` runs in
the switch lock, just before `darwin-rebuild switch`. When the deploy changes
the decapod package (Home Manager's package for dktaohan is not on the symlink
path of the installed `decapod`), the script copies the store with SQLite's
online backup. The store opens read-only, so agents can write during the copy.
The copy goes, readable only by the user (umask 077), to
`~/.local/state/den-decapod-backups/<UTC time>-<old>-to-<new>.db`, not into
`~/.local/state/den`: that directory holds only the Decapod PAUSE marker, and
the G5 marker test runs only when it creates the directory itself. It must
pass `PRAGMA integrity_check` and have pages, and the newest 5 copies stay.
The deploy stops, and a failed copy is removed, when the evaluation fails or
takes more than 30 minutes (it can fetch the new flake inputs of a bump over
slow Wi-Fi), when it finds no decapod package or more than one, and
when the copy or its check fails. To deploy without the copy on purpose, for
example when the store itself is broken, run
`DEN_SKIP_DECAPOD_BACKUP=1 just deploy-darwin`.

A copy is a rollback point, not a restore. Only the owner restores a copy,
with every agent stopped. The copy is made before `darwin-rebuild switch`
builds, and on a cold cache the build takes minutes. Agents' writes during
the build are not in the copy, so a restore loses them. The supported Decapod backup,
`decapod data database backup`, runs only in a Decapod workspace, so a deploy
cannot use it.

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

### azure-cli is a Homebrew cask (M-02877)
On 2026-11-09 Homebrew removed the `azure-cli` formula and shipped it as a
cask. `brew bundle` in activation then failed with 'No available formula with
the name "azure-cli"', which broke every deploy. `modules/M-02877/darwin.nix`
now lists `azure-cli` under `homebrew.casks`, not `homebrew.brews`. The old
formula keg (2.90.0) stays installed, and its `az` link collides with the
cask's binary, so run `brew uninstall --formula azure-cli` once, right before
the first deploy of this change. The Brewfile must contain `cask "azure-cli"`
and no `brew "azure-cli"`.

### Decapod binary name (DecapodLabs/decapod#1582, fixed)
Upstream's `packages.default` is a `makeWrapper` script, `bin/decapod`, that
execs `bin/.decapod-wrapped`. Before the fix, `decapod qa verify` and `decapod
todo done --validated` ran `std::env::current_exe()` under the
`verification_exec` capability, which rejected the name `.decapod-wrapped`, so
plain `decapod validate` reported PROOF_HOOK_FAILED for every done todo. Den #133
worked around that with an overlay that copied the real binary to
`libexec/decapod/decapod`. #1582 is fixed since Decapod 0.134.2, and
a scratch Decapod repository showed that `qa verify` and `todo done --validated`
start the validation child from the plain upstream package with no
`.decapod-wrapped` rejection. So `modules/overlays.nix` again takes
`inputs.decapod.packages.<system>.default` unchanged, and the version, `meta`
and `passthru` are upstream's. Do not add the copy back unless a Decapod release
brings the rejection back.

### pr-reviewer (M-02877)
`modules/M-02877/pr-reviewer.nix` runs the PR review daemon as the launchd
agent `com.dktaohan.pr-reviewer`, built from the flake that
`worldofgeese/pr-reviewer` ships (den's `pr-reviewer` flake input,
`packages.default`), pinned to its v0.2.6 release (commit f37546e; the
maintained home of the project since the 2026-11 move from
`NicholaiVogel/pr-reviewer`). The input URL names the release tag and
`flake.lock` pins the revision, so den holds no hand-maintained rev, source
hash or `cargoHash`; the flake builds from `Cargo.lock` with the tests off,
because the suite binds loopback sockets that the Nix sandbox refuses. The
build carries no local patches: HTTPS Basic auth for git, review rounds and
stacked PRs are all in the pinned release. v0.2.6 over v0.2.5: a head claim
that a killed daemon left behind no longer blocks a merge (worldofgeese/pr-reviewer#42;
this answers the review thread on den#151). v0.2.5 over v0.2.4: a head claim
(worldofgeese/pr-reviewer#40, issue #36 option 3) keeps two hosts off one head
commit. Before a review cycle the daemon sets a `pending` commit status with
the context `pr-reviewer/claim` and the description `claimed by <host> at
<UTC time>` on the head, and skips a head while another host's claim is under
15 minutes old (it checks again after 2 minutes). It reads its claim back,
backs off when a peer's fresh claim is the latest, and posts a `success`
status `released by <host>` when the cycle ends or fails. So the claim is
`pending` only while a review cycle runs, and a reviewed head ends in
`success`. GitHub statuses never expire, so a daemon that dies inside a cycle
(a kill, a restart, a sleeping machine) would leave a `pending` claim, and the
automerge rule below (every check complete) would wait on it for good. v0.2.6
releases such a claim with the same `success` status: at start, before any
review cycle, it releases a `pending` claim that its own host made, on every
open PR of the declared repos; while it runs, it releases a `pending` claim of
any host older than 15 minutes on a head it already reviewed (it looks at
each reviewed PR about every 15 minutes), and the review engine does the same
when it skips an already-reviewed head. It never touches a peer's claim under
15 minutes old, and with `defaults.dry_run` on it releases nothing. To clear a
stuck claim by hand: `gh api repos/OWNER/REPO/statuses/HEAD_SHA -f state=success
-f context=pr-reviewer/claim -f description="released by hand"`. The claim
needs no setting and no database change. It works only if the daemon's token
can write commit statuses (a peer daemon needs v0.2.5 or later and such a
token for its claims to count); without that the daemon logs `could not set the
head claim` and reviews as v0.2.4 did. The status shows the machine's host name
to anyone who can see the pull request, and the claim is a best-effort guard,
not a lock. Two daemons on one machine would share a host name, and v0.2.6
would then release the other's claims at start, so run one daemon per machine.
v0.2.4 over v0.2.3: peer daemons
(worldofgeese/pr-reviewer#37, #38): `defaults.peer_logins` names other
people's daemons on the same repos, whose reviews, skips and command answers
count as done, and `defaults.standby_delay_secs` makes a standby wait; both
are off unless set, and the database gains the nullable
`work_queue.not_before` column at the first start. v0.2.3 over v0.2.2: a `claude`
review session starts with `--tools <review_tools>` (default none, so no
`Bash`, file reads or edits) and `--strict-mcp-config` (no user-level MCP
servers); auto-fix sessions keep `Read,Grep,Glob,Edit,Write,Bash`; this
configuration sets no `review_tools`, so reviews run with no tools. v0.2.2 over
v0.2.1: `@pr-reviewer fix` works for org members (own comments are skipped only
with a pr-reviewer marker and the daemon's login), `remove` warns about the
settings it discards while `list` and `status` show `auto_fix`, an exclusive
lock on `daemon.lock` allows one daemon and the start-up sweep requeues work
that a dead daemon left claimed, and the opt-in `status_on_no_new_findings`
posts a commit status when a re-review finds nothing new (off unless set in
`[defaults]` or a repo's `review_policy`; this configuration leaves it off).
To move to a newer release, change the tag in the input URL in `flake.nix`, run
`nix flake update pr-reviewer` and deploy; the review rounds and stacked-PR
behavior below are v0.2.2's and unchanged since.

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
  LEGO/agentic-engineering-community, LEGO/ai-daily-assistant,
  LEGO/team-friendship-hour, worldofgeese/pr-reviewer and worldofgeese/den.
  worldofgeese/pr-reviewer is the daemon's own repository (dogfooding): it is
  reviewed and automerged under the same policy as the others, and the machine
  runs the pinned release of that repository, so a fix merged there reaches
  the machine only after the pin in the same file moves. worldofgeese/den is
  this configuration repository (added 2026-11-05, approved by Tao): its PRs
  are reviewed and automerged under the same policy, and den's Codex shepherd
  labels a PR `needs-human` when its quota runs out, which the automerge
  skips.
- **Peer daemon.** sethpjacobs runs a standby pr-reviewer on his Mac for five
  of the declared repos (`standby_delay_secs` 600, the same model, auto-fix
  off), so reviews go on while this Mac is off. This daemon is the primary:
  its runtime config must name `sethpjacobs` in `defaults.peer_logins` and
  leave `standby_delay_secs` at 0 (`pr-reviewer config set`, not Nix). It skips
  a head commit or a command that the peer already handled. A fix request
  stays with this daemon: the peer, with auto-fix off, answers it with
  `repair=off`, which does not stop the repair here. Each daemon dismisses
  only its own change requests; the automerge sets a superseded one aside.
- **PRs opened before a repo was added** are reviewed too: each poll queues
  every open PR whose head SHA has no recorded review, so the first poll after
  registration picks up the existing backlog.
- **Runtime state** (config.toml with the machine-bound encrypted token,
  keyfile, state.db, managed clones) stays in
  `~/Library/Application Support/pr-reviewer` and is mutated only by the CLI.
- **Never start it by hand.** Since v0.2.2 a second `pr-reviewer start`
  fails on the `daemon.lock` lock instead of double-reviewing every PR, but
  launchd still owns the process. Restart with `launchctl kickstart -k gui/$UID/com.dktaohan.pr-reviewer`.
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
- The PR is not a draft and has no `hold`, `do-not-merge` or `needs-human` label.
- The author is worldofgeese, `app/github-actions` or `app/dependabot`.
  Teammates' PRs stay manual.
- `pr-reviewer queue list` has a completed `review_pr` task at the PR's
  current head SHA, or a trusted account posted a pr-reviewer review (one
  with pr-reviewer's review metadata) of that head. The trusted accounts are
  worldofgeese and the daemon's `defaults.peer_logins`, read from the runtime
  config once per pass; a list that cannot be read counts as none. A head
  that the daemon skipped because a peer reviewed it is a completed task too.
- No review thread is unresolved, and no review requests changes. A
  pr-reviewer change request from one trusted account is set aside once
  another trusted account approved or only commented on a later commit of the
  PR, because a daemon dismisses only its own change requests and skips a head
  that its peer reviewed. "Later" is the order of the PR's commits, which the
  agent reads with one more GraphQL query per pass, only for a repo where
  GitHub reports a change request; a request on a commit that a force-push
  removed goes by time. A change request on the head itself is never set
  aside: a review that started before a push can land later for an older
  commit. The agent logs each one it sets aside. A person's change request
  still blocks.
- Every check is complete with SUCCESS, SKIPPED or NEUTRAL. A PR with no
  checks also qualifies. The `pr-reviewer/claim` status counts like any other
  check: it is `pending` during a review cycle, `success` once released, and
  v0.2.6 releases a stale one (see the pr-reviewer section). The agent does
  not special-case it.
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
that only logs. To hold a PR, label it `hold`. A `needs-human` label holds it too. To stop merging, run
`launchctl bootout gui/$UID/com.dktaohan.pr-reviewer-automerge`.

#### Live end-to-end test
The private repo `worldofgeese/pr-reviewer-livetest` is a test target that
notifies nobody else. It is deliberately *not* in the declared list.
1. `pr-reviewer add worldofgeese/pr-reviewer-livetest`. This exercises the
   HTTPS managed clone. Then restart while idle (above).
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

Personal-first Signet (since 2026-11-04, the owner's decision to capture every
memory in the personal Signet): every Signet client on M-02877 uses the
personal daemon on 3850, whatever the repository. This reverses the
2026-10-06 move of all clients to the team pool; the memories exported then to
`~/signet-handover/` stay there. The team pool is reached by:

- the `signet-auto-curator` launchd agent (`modules/M-02877/agent-integrations.nix`).
  Every 600 s (`StartInterval`, no `RunAtLoad`) it runs
  `~/projects/devrel-infra/projects/aws-signet/tools/memory-curator/auto.py`
  (`./run auto`), which publishes team-level personal memories to the team pool
  and mirrors the pool back into the personal Signet, so one daemon serves
  recall. `CURATOR_PERSONAL` lists the repositories and machines whose notes
  never become team facts. The log is `~/.local/state/signet-auto-curator.log`.
  devrel-infra is internal and this flake is public, so the script cannot be a
  flake input; it runs from the main clone. Until the devrel-infra pull requests
  that add `auto.py` merge and that clone updates, each run fails harmlessly.
- a shell with `SIGNET_STORE=team` exported (see `_signet_store`).

Gateway shim key (since 2026-11-04): `com.dktaohan.signet-gateway-shim` takes
its key from `gateway.keyCommand`, the command pi uses, not from a copy in
Signet's secret store. That copy went stale and the shim answered 401 "Invalid
authentication" until the current key was stored there by hand. The shim reads
the key once, at start: after a rotation, run
`launchctl kickstart -k gui/$(id -u)/com.dktaohan.signet-gateway-shim`.

The team pool needs the `SIGNET_*` session variables in every shell. A herdr
pane starts with the herdr server's environment, which is as old as the
server, `__HM_SESS_VARS_SOURCED` included, so Home Manager's source-once guard
skipped every variable added since. Restarting WezTerm does not help, because
herdr keeps its server. On 2026-10-08 the server dated from 2026-09-30, its
panes had no `SIGNET_*`, and pi fell back to the personal daemon as agent
`default`. `programs.zsh.envExtra` (dktaohan.nix) now loads
`hm-session-vars.sh` once per `HERDR_PANE_ID`. A pi started before that keeps
its old environment: start it again in a new pane.

The live personal daemon still reported 0.238.0 on 2026-11-10. The source
now selects the digest-pinned 1.0.1 security release. A pin change alone does not update
an existing container: `podman container exists signet` skips creation.
The host CLI is exported from that container, so both versions move together.

The 1.0.0 image passed an isolated architecture probe and a migration rehearsal
on a private workspace copy. Readiness, SQLite integrity, tracked table counts,
and memory content, scope, provenance, and tags were preserved. The verified
backup remained unchanged. That rehearsal is not a completed live upgrade.

Signet 1.0.1 was published later on 2026-11-10. It fixes source-import file
access, cross-agent memory access, cross-site writes, session permissions,
and connector file modes. A fresh rehearsal from the original private backup
passed with 1.0.1: readiness returned 200, a foreign-origin write returned 403,
memory content and scope stayed identical, and SQLite integrity passed. The
backup stayed unchanged and the test container was removed. Deploy that
security release rather than the superseded 1.0.0 candidate. Run `signet sync`
after the live upgrade and verify the affected connector modes.

For the live migration:
1. Coordinate a quiet window for Signet clients. Record the old image, container,
   job definition, and private workspace backup. Verify that backup first.
2. Boot out `com.dktaohan.signet-container`. Rename the existing container to a
   unique rollback name, for example `podman rename signet signet-before-1.0.1`.
   Then stop that renamed container with `podman stop --time 30 signet-before-1.0.1`.
   Renaming prevents the exported CLI from restarting the old `signet` name.
3. With the old daemon stopped, preserve the final private workspace state.
   Keep the original container and data backup until verification passes.
4. Deploy the reviewed image pin. Let activation start the installed job, or
   bootstrap it if it remains unloaded. The `signet` name is now free, so the
   job creates the new container. Initial Distrobox setup can take several minutes.
5. Verify the live version, workspace, readiness, scoped recall, inference,
   connector behavior, and personal/team boundary. Refresh the Pi connector
   only through Signet's supported command and preserve private file modes.

Rollback requires more than the old container. Stop the new job and container,
preserve the failed container and upgraded workspace for inspection, and free
the `signet` name. Restore `~/.agents` from the verified pre-migration backup
while clients are stopped. Rename the old container back to `signet`, then
bootstrap the job and verify the restored version and data. Do not start the
old binary against a database that the new release migrated.

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

Caveman runs in Pi without its cloud features. The npm CLI owns the native
release selection; den owns the proxy service, routes, and extension shim.
On 2026-11-10, CLI 4.1.0 and the running `bin-v4.1.0` proxy were verified.
The six native files matched the installer's hashes. `/health/live` returned
200 with the expected instance identity, and the recovery-store check passed.

For an update:
1. Preserve the existing CLI, binaries, configuration, and private SQLite stores.
   Use SQLite's backup API for live databases. Check the copies before proceeding.
   A standalone backup can need `PRAGMA journal_mode=DELETE` on the copy before
   a read-only `PRAGMA quick_check`; do not change the live database's journal mode.
2. Install the selected CLI with `npm install -g @caveman-ai/cli@4.1.0`.
3. Run `caveman setup --install --json`. This installs only the native binaries.
   `--agents` cannot be combined with this form. Preserve the installer result.
4. Keep cloud routing and telemetry off. `caveman telemetry off` records that
   choice; den also sets `DO_NOT_TRACK=1` for the proxy and hook CLI.
   If module setup is needed, run `caveman setup --agents none` separately.
5. Coordinate a quiet window and hold the M-02877 switch lock. Use a control
   session whose model requests do not depend on the proxy being restarted.
   Request `SIGTERM` through the existing `com.dktaohan.caveman-proxy` launchd job.
   Its documented drain is five seconds, so a long request can require a retry.
6. Verify the new PID, native version, `compress` mode, `start` ownership, MCP
   recovery, and `/health/live`. Compare instance identities without printing them.
   Run `caveman-proxy recovery-store check`; a version string alone is insufficient.

An open pooled socket is not proof of an active model request. The first
2026-11-10 socket-count check prevented a restart; the supported drain worked.
The first readiness probe used an incorrect URL. Correcting it to `/health/live`
verified the already-running proxy without another restart.

The release now includes the prompt-cache fix from #1376. The old binary
replacement and npm-bundle patch are retired. Existing Pi sessions still need
a reload to use newly installed extension code.

Do not install `caveman-native.js` beside den's shim. Blocks is a separate,
optional component; a native-binary update does not resolve its Codex hook
issue or add a Pi harness.

The modules and pi, measured on 2026-10-15:
- `output`, `input`, `waste-fixes` and `browse` are on.
- `scripts` (Caveman Blocks) is on for Claude Code and Codex. Blocks has no pi
  harness yet (caveman-ai/blocks#11). Its Codex entry runs `--harness claude`,
  which we asked about in caveman-ai/blocks#12. The current upstream profile
  intentionally uses that grammar for Codex; its `codex` alias selects the
  same parser. The label alone does not establish a failure. Verify actual
  host events rather than changing it blindly. Blocks follows the Caveman
  telemetry decision in `cloud.json`, which is off since 2026-10-23.
- `routing` is off. Auto (`caveman-auto`) reaches only the Claude Code and
  OpenCode model pickers, not pi (JuliusBrussee/caveman#1286). It also needs a
  Caveman Cloud sign-in, and each routed request sends the latest prompt (up
  to 128 KiB), the prompt before it and the last reply to Caveman Cloud. That
  is a cloud feature, and we do not use cloud features.

Historical measurements, not a benchmark of the current release: one Pi
session on 2026-10-23 (pi 1.4.0,
Claude Haiku 4.5, the same 8 prompts per run, `~/.cache/chain-test/cave-max.sh`):

| Run | Cache-write tokens | Cost |
|---|---:|---:|
| No Caveman extension | 38,685 | $0.107 |
| Released extension, `bin-v4.0.2` runtime | 131,658 | $0.234 |
| Extension from #1376, `bin-v4.0.2` runtime | 35,975 | $0.112 |
| No extension, requests through a `bin-v4.0.2` compat mount | 40,089 | $0.112 |

Caveman behaviours that shape this design:
- Default Anthropic and OpenAI upstreams must name the approved gateway.
  Leaving a public default can disclose the gateway credential. Named compat
  mounts send normal model traffic through Headroom.
- pi sends the key as the bearer and as `x-api-key`. The gateway accepts only
  the bearer. A `bin-v4.0.2` compat mount with `wire_dialect: anthropic`
  forwards the bearer and compresses Anthropic requests. It compressed a JSON
  and log tool result from 29,956 to 867 tokens. It does not compress prose:
  pi's markdown tool outputs, already trimmed by RTK and context-mode, come
  through unchanged. Since 2026-11-01, `lego-claude` uses the `lego-claude`
  mount (see "pi through the chain").
- Pi must name the real upstream so the extension can prove the route.
  Changing only that URL is insufficient: the old empty `x-api-key` override
  also fails the header check. Removing both obsolete workarounds passed the
  router regression; the compat mount preserves matching bearer credentials.
- Release 4.1.0 includes the native-store fix for #1279. Keep runtime and
  recovery checks separate from the CLI version check. Outputs below 4096
  bytes remain unmasked, and a recovery query is explicitly an excerpt.
- Since 4.0.1, the extension does not shrink tool output in a session that
  cannot call `caveman_retrieve` (#1211). So the den-generated `techwriter`
  agent does not name `caveman_retrieve` in its `tools:`.

The shim (`~/.pi/agent/extensions/caveman.js`) only loads the npm-installed
extension (`dist/caveman-pi-extension.mjs`).

#### Independent reviewer

Reviewer-agent 1.4.8 is installed for Claude Code from the permanent checkout
`~/.local/share/reviewer-agent`. Its project backend is Pi. The 309 Claude
smoke tests, layering check, 55 Git-tool tests, and 8 real-Git tests passed.
This is separate from the existing GitHub `pr-reviewer` daemon.

The default Pi reviewer process inherited global compactors. In a real probe,
its 30,964-byte staged diff became a 187-byte recovery pointer, but the reviewer
could not call the recovery tool. It missed two of three sentinel values.
The isolated process read the complete diff and returned all three values.

Den supplies `~/.local/bin/reviewer-pi` for that role. It loads only the
read-only Git extension and the mandatory Decapod prompt gate. Its final tool
allowlist excludes Bash, edit, and write, even if the caller supplies a broader
list. Main Pi sessions keep their normal extensions. After deploying the launcher, set reviewer-agent's
relocation-aware `config_file()` `piBin` field to that absolute path and verify
that the hooks resolve it. Preserve all other reviewer configuration.

Both review switches remain off, and no risk receipt was created. A fresh
Claude Code session must load the plugin before the operator confirms settings
and performs any exact risk-acceptance invocation. The first real reviewed
commit is the end-to-end gate check; installation tests are not that proof.

The Codex adapter is not installed. Its 1.4.8 suite fails
`test_reviewer_launch_environment_remains_stable`: Git inherits a nonexistent
`TMPDIR` and cannot create a commit when SSH signing is enabled. Do not disable
signing or skip the test to make this adapter appear ready.

#### Headroom 0.41.0 fixes

Headroom 0.41.0 (released 2026-10-14) introduced the fixes
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

#### Headroom storage admission

The pre-rollout check found ext4 metadata errors on the live `headroom-data`
volume, including an unreadable, unopened temporary file from the atomic
savings writer. The canonical savings JSON is valid and all 1,587 SQLite files
passed read-only `quick_check`; that does not make the filesystem healthy.
Preserve the original volume and use the clean `headroom-workspace` volume as
the configured target. The launch script rejects an unavailable or malformed
volume inventory and refuses to replace a legacy instance until that target
exists. It also checks image availability before stopping the old container.
The target's existence is not proof of a complete restore. Restore and verify
into `headroom-workspace` first; quiesce Headroom writers, refresh the final
copy, and only then switch. Use `lego-claude-direct` or a control terminal that
does not depend on Headroom during this work. A new host with no legacy volume
keeps normal initialization.

A blocked guard logs its reason to `/tmp/headroom.err`; launchd KeepAlive retries
it. If it blocks after a switch, finish the verified restore or roll back to the
previous generation, which still mounts `headroom-data`. That restores the old
availability path, not filesystem health; retain the damaged volume and backup.

A private restore rehearsal verified 1,641 workspace files, started Headroom
0.44.0 on a fresh native volume, and compared 1,586 non-empty SQLite databases
across 6,866 ordinary tables without a removed or changed existing row. The
empty legacy database file was also preserved. Temporary resources were removed.
The online backup is a recovery point, not a global snapshot of later writes;
quiesce writers and refresh mutable state at cutover. Keep the original volume
and private backup afterward. Do not run filesystem repair on a mounted volume.
Offline repair is a separate owner decision after the backup.

#### Dagger engine version and rollback

`Justfile` pins the Dagger engine to beta.27 by digest. A new CLI does not
upgrade `den-dagger-engine`, and `just dagger-check` deliberately preserves an
existing container. Query the running engine separately with `dagger query
--no-load-module` and a `{ version }` request before claiming a version update.

Use the shared switch lock for the live replacement. Check for active clients,
stop the engine cleanly, and export the `dagger-engine-den` volume through
Podman before changing its image. Keep the old container under a rollback
name and retain the volume archive privately: engine caches can contain source
code. Verify the new engine and a synthetic workload before dropping rollback
material. If the new engine changes persisted state and must be reverted, stop
it and restore the volume as well as the old container. An old image alone is
not a complete data rollback. For source rollback, restore both the module's
`engineVersion` and `dagger_engine_image` to beta.21, with engine digest
`sha256:3444c48e871bedaa95f5b1e57b8c41de929d9e061dd75e9ac6f6deb1f0a74bc3`.

#### pi through the chain

An isolated 2026-11-10 probe used Caveman 4.1.0 and Headroom 0.44.0 with real
Haiku Messages and GPT-6 Luna Responses requests. All six requests succeeded
and preserved three synthetic sentinel values. The final Claude request read
13,180 cached input tokens without a cache write; OpenAI read 11,625 cached
tokens and wrote 14. Temporary services were removed. This proves the tested
protocol, authentication, fidelity sample, and cache boundaries, not a net
cost saving or a completed live rollout.

Normal Pi sessions still have an end-to-end recovery limit with context-mode
2.1.7: it can replace a Caveman recovery response with another search pointer.
The stored bytes remain available, but the recovery tool does not return them
intact to the caller. No per-tool exemption is exposed. This needs an upstream
fix; native recovery-store integrity alone does not prove end-to-end recovery.
The isolated reviewer avoids that combined compaction path.

The configured Pi routes are defined by `agentProviders.pi` and its optional
`openai` route in `modules/M-02877/token-toolchain.nix`:
- Pi names Headroom directly: its root for Claude, and `/v1` for OpenAI.
- Caveman selects `/w/pi/compat/lego-claude` or
  `/w/pi/compat/lego-openai/v1` only after route and recovery checks pass.
- Both mounts forward the bearer and `x-headroom-cwd`. The Claude mount uses
  `wire_dialect: anthropic`; the OpenAI mount preserves Responses API shape.
- `CAVE_SSRF_ALLOWLIST=127.0.0.1` permits only the required loopback upstream.
  Caveman 4.1 reports a refused upstream as `cave_upstream_blocked`.
- Headroom receives explicit Anthropic and OpenAI gateway targets. The OpenAI
  API root in `gateway.json` excludes `/v1`, which Headroom appends itself.

A provider URL that already names Caveman defeats the extension's route proof.
An empty `x-api-key` override also fails. Neither workaround belongs in the
managed proxy route. When routing is not established, Pi uses its configured
Headroom upstream; transparent failover of an in-flight request is not promised.

Keep a control path outside any proxy being restarted. A plain terminal is one
option. `lego-claude-direct` and `lego-openai-direct` preserve the selected
model catalog and authentication while reaching the approved gateway directly.
Provider activation keeps the user's saved default and unrelated providers.

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
`systemd-inhibit`, `systemd-run --user`) with
`hyprctl dispatch 'hl.dsp.exit()'`, elogind
`loginctl`/`elogind-inhibit`, and `setsid --fork`. The build fails if any
uncommented systemd call remains. Omarchy 4.5.0-rc2 merged the old
`omarchy-system-{logout,reboot,shutdown}` scripts into `omarchy-system`.
nixarchy replaces `enable-user-units.sh` with a no-op. The guard patches that
script only while it still calls `systemctl`.

Hyprland's Lua configuration does not accept `hyprctl dispatch exit`.
It interprets that argument as `hl.dispatch(exit)`, but the global `exit`
does not exist. The launcher then reports `Logout failed`. Use the Lua
dispatcher constructor `hl.dsp.exit()` through `hyprctl dispatch`.

### mahakala desktop: the EWM session

GDM's EWM entry comes from the `ewm-desktop-session` package in
`guix/system.scm`. Its `ewm-session` script only runs the Home Manager
`ewm-start` launcher from `modules/workstation.nix`. That launcher unsets
`EMACSLOADPATH` and `EMACSNATIVELOADPATH`, then starts the Nix `emacs-pgtk`
with the `ewm` and `ewm-core` store paths on its load path.

Until 2026-11-02 the Guix script started the Guix Emacs (glibc 2.41) and
loaded the Nix `ewm-core.so` (glibc 2.44). The module load failed with
`version GLIBC_2.44 not found`, Emacs exited, and GDM reported
"authentication error". GDM remembers the last session, so the error remained
after the Omarchy fix until the user picked Omarchy again. Guix also exports
`EMACSLOADPATH` without a trailing colon. A Nix Emacs that inherits it cannot
find its own lisp (`Cannot open load file ... cl-lib`), so the launcher must
unset it.

- **Check**: run the `emacs` from `ewm-start` with `--batch`, its `-L` flags
  and `-l ewm`, with `EMACSLOADPATH` unset. `(featurep 'ewm-core)` must be
  `t`.
- **Deploy**: the change needs both the HM deploy (for `ewm-start`) and
  `just deploy-mahakala-system` (for the new `ewm-session`). Until HM is
  deployed, `ewm-session` prints an error and exits.

### mahakala desktop: Omarchy on elogind

`modules/omarchy.nix` keeps nixarchy's Quickshell patches and changes its
polkit dependency to use elogind. The default systemd library cannot find
the Guix desktop session. The agent then reports `No session for pid`.
The polkit client uses `/run/privileged/bin/polkit-agent-helper-1`, which
Guix supplies, instead of the NixOS path `/run/wrappers/bin`.

The keyboard indicator requires PyGObject and GLib typelibs. Its QML process
uses a Nix wrapper that supplies both dependencies. A plain Python
interpreter cannot import `gi`. Guix also has no `/usr/bin/python3`.
The Suspend and Hibernate menu actions use Guix's `loginctl`, not `systemctl`.

The bar settings remain writable in `~/.config/omarchy/shell.json`.
On 2026-11-02, this file used an opaque background and `alwaysShow` for
`omarchy.indicators`. The clock used identical `format` and `formatAlt`
values to prevent a width change on hover. These settings survived the
Home Manager generation 364 and 365 deployments. A cropped screenshot
confirmed the opaque bar after the shell restart. The clock formats match;
the pointer-hover behavior still needs user verification.

Do not restart Quickshell while its session lock is active.
Deploy the profile first. Unlock the desktop before a shell restart.
With generation 365 active, the live shell logged `omarchy polkit agent
registered`. Its keyboard indicator process stayed active. The
`learn.keybindings` menu route displayed the populated Keybindings dialog
after the shell restart. The original failure did not recur.

The bar's menu button shows the Guix logo (`guixMenuIcon`: `logo/Guix.svg` from
the Guix artwork commit that Guix's `guix-icons` uses, rasterized to PNG
because this Quickshell build has no SVG image plugin) instead of nixarchy's
NixOS snowflake.

The PowerProfilesDaemon service remains absent. Its warning does not prevent
the bar or Keybindings dialog from starting.

Launcher actions that assume Arch or systemd are replaced at build time by
scripts in `scripts/omarchy-guix/`, installed over `share/omarchy/bin`:

- Install and Remove (`omarchy-pkg-add`, `-pkg-install`, `-pkg-aur-install`,
  `-pkg-remove`, `-pkg-drop`) map Arch names through nixarchy's
  `nixarchy-arch-packages.tsv` and app table to nixpkgs attributes. They edit
  `modules/omarchy-apps.json` in the den checkout (`DEN_DIR`, default
  `~/.config/home-manager`) and run `just deploy-mahakala-hm-only`, restoring
  the list if the deploy fails. NixOS options and PHP extensions are refused.
  `pkg-drop` only removes entries from that list and fails for anything
  declared elsewhere, which stops the `omarchy-remove-*` scripts safely.
- `omarchy-update` fast-forwards den and runs the three mahakala deploys.
- `omarchy-channel-set`, `omarchy-refresh-plymouth`, and `omarchy-dns` explain
  what governs that setting here (the nixarchy input, no Plymouth, Tailscale
  MagicDNS) instead of acting.
- The timezone menu lists `tzdata`'s `zone.tab` and edits `(timezone ...)` in
  `guix/system.scm`, then deploys the system. New logins pick it up.
- Reminders use detached `setsid` sleepers with state in
  `$XDG_RUNTIME_DIR/omarchy-reminders` instead of `systemd-run` timers.
- Crash capture (systemd-coredump) reports that it is unavailable; XCompose
  restarts fcitx5 when present.

The build fails if `systemctl`, `systemd-run`, `timedatectl`, `pacman`, `yay`,
or `nixos-rebuild` remains in a patched script. On 2026-11-02 the reminder
lifecycle (set, `show --json`, clear, sleeper killed), the timezone list, DNS,
channel, Plymouth, and the `pkg-add` refusals were exercised on mahakala.
The EWM module load check passed, but a full GDM login remains unverified.

### mahakala boot: one password, and agent reboots

`/boot` is inside the LUKS1 root (`cryptroot`), so GRUB asks for the disk
passphrase. Guix passes GRUB's volume key to the initrd through
`(proc)/luks_script`, so the initrd does not ask again. GDM autologs in
`worldofgeese` (`guix/system.scm`, `gdm-configuration`). A cold boot therefore
needs the passphrase once. Autologin gives the GNOME keyring no password to
unlock with, so on 2026-11-02 the `login` and `Default_keyring` keyrings were
re-keyed to an empty password (`ChangeWithMasterPassword` over the Secret
Service). They now open at login without a prompt and are stored unencrypted
in `~/.local/share/keyrings`; LUKS protects them at rest. gnome-keyring 48
crashes when it has to show a gcr prompt, so a keyring that needs a password
again cannot be unlocked from the GUI. Re-key it the same way.

The GRUB menu is hidden: `bootloader-configuration` sets `(timeout 0)`, and
`grub-efi-hidden-menu-bootloader` in `guix/system.scm` adds
`set timeout_style=hidden` to the generated `grub.cfg`, because Guix has no
field for it. GRUB boots the default entry straight after the passphrase and
checks for keys once. Hold Shift, or press Esc or F4, while it starts to get
the menu (old generations, for example).

An agent can reboot to the desktop without the user. `sudo agent-unlock
reboot` (`guix/agent-unlock.sh`, package `agent-unlock`) performs these steps:

1. It writes a random 64-byte key into LUKS slot 7. It uses the volume key of
   the open mapping, so no passphrase is needed.
2. It copies that key to `/boot/efi/EFI/agent-unlock/key`.
3. It builds a standalone GRUB image at `/EFI/agent-unlock/grubx64.efi`. That
   image tries the key, falls back to the normal passphrase prompt, and then
   loads Guix's `grub.cfg`.
4. It creates an `Agent unlock` boot entry with `--create-only`, so the entry
   never enters `BootOrder`.
5. It sets `BootNext` to that entry and reboots.

The one-shot `agent-unlock` Shepherd service runs `agent-unlock cleanup` on
every boot. It removes slot 7 and shreds the ESP key, so each key opens the
disk at most once. It also writes `/run/agent-unlock/boot-mode`: `agent` when
slot 7 or the ESP key was still present, `interactive` otherwise. The firmware's
`BootCurrent` is not used, because this Dell reported `0000` (a stale Garuda
entry) after a verified `BootNext` agent boot.

On a host with `/etc/agent-unlock`, the patched Omarchy lock screen
(`modules/omarchy.nix`, `agentBootLockCheck`) locks once per boot unless the
mode reads `interactive`. A missing mode locks, so the check fails closed.
The session user releases only that lock with `just mahakala-session-unlock`
(`omarchy-shell lock unlock`) over tailnet SSH. `just mahakala-agent-reboot`
is the whole reboot. That call returns `denied` for any other lock.

Tradeoffs:
- Between arming and the next boot, the key is readable on the FAT ESP.
- GRUB tries slot 0's slow PBKDF before slot 7.

Slot 0, the user's passphrase, is never modified.

Deep sleep is the default (`mem_sleep_default=deep`). Overnight S3 drained
about 98 mAh/h.

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

The nightly bump (`scripts/bump-flake-inputs.sh`) rewrites this section. On 2026-11-11 it changed 12 nodes of `flake.lock`.

| Node | Before | After |
|---|---|---|
| `decapod` | 53a5574 (2026-11-11) | 2f6daf8 (2026-11-11) |
| `den` | bf2504f (2026-11-06) | 1ebb7de (2026-11-11) |
| `devenv` | 08d11dc (2026-11-10) | 622870a (2026-11-11) |
| `emacs-overlay` | 5f55562 (2026-11-09) | 4b57c40 (2026-11-10) |
| `ewm` | 9c5325e (2026-11-07) | 8719dd6 (2026-11-10) |
| `helium` | 9fe3f8f (2026-11-05) | ee8c73c (2026-11-10) |
| `llm-agents` | 87add08 (2026-11-10) | b1794bc (2026-11-11) |
| `nix-doom-emacs-unstraightened` | 4520f99 (2026-11-09) | c2103e4 (2026-11-10) |
| `nixarchy` | f11f4c5 (2026-11-10) | 07323b9 (2026-11-11) |
| `nixpkgs_5` | f9a75f4 (2026-11-05) | f4a03c0 (2026-11-07) |
| `rust-overlay_3` | b705383 (2026-11-09) | 0070500 (2026-11-11) |
| `zen-browser` | 37ba4a6 (2026-11-06) | a7cac93 (2026-11-11) |

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

- Repository signal fingerprint: `1f0e237bebd028d6cce308b8d565edab214343d8e3160673040e1cdaf6af1404`
- Significant implementation surfaces: `.beads/` (1 files), `.dagger/` (12 files), `.github/` (5 files), `README.md/` (1 files), `docs/` (2 files), `modules/` (1 files), `scripts/` (9 files), `terraform/` (1 files)
- Refreshed from the current codebase by `decapod rpc --op specs.refresh`
<!-- decapod:codebase-attestation:end -->
