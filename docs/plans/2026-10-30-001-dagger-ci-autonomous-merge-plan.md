---
title: "plan: Replace den CI with a Dagger pipeline that checks, reviews, fixes and merges each PR"
status: active
created: 2026-10-30
type: plan
depth: standard
origin: user request on 2026-10-30; bead home-manager-1l3
---

# plan: Replace den CI with a Dagger pipeline that checks, reviews, fixes and merges each PR

## Problem Frame

den has three CI parts today, on two kinds of host:

| Part | Where it runs | What it does |
|---|---|---|
| `.github/workflows/decapod-validate.yml` | GitHub Actions | Runs `decapod validate --refresh-specs` and a drift check |
| `com.dktaohan.pr-reviewer` (`modules/M-02877/pr-reviewer.nix`) | launchd on M-02877 | Reviews each PR with NicholaiVogel/pr-reviewer and two local patches |
| `com.dktaohan.pr-reviewer-automerge` | launchd on M-02877 | Merges a PR after a review of its head commit |

`just check` runs only on a workstation. CI does not run `check-drvpaths.sh`, `check-fmt`, `check-guix` or `check-decapod-overrides`.

These failures were measured on 2026-10-30:

- PRs #24 and #25 are open since 2026-10-05. Their `validate` check passes. Nothing merged or closed them.
- Five issues are open (#55, #57, #59, #60, #61). No agent works on them.
- The reviewer and the merger run on a laptop. They stop when M-02877 sleeps.
- The CI workflow installs the newest Decapod (`cargo binstall decapod`) and caches it under a key from the hash of `AGENTS.md`. den pins 0.111.6, but the pin holds only while that cache entry lives. Local `validate` cannot pass at all (den#61).
- Each topgrade run deploys a `flake.lock` that nobody committed (den#60).
- On 2026-10-30 topgrade deployed a main checkout that did not have PRs #52, #64, #65 and #66. `scripts/deploy-freshness.sh` now stops such a deploy, but only on M-02877.
- `main` has no branch protection. A merge needs no check.

**Goal.** Every change reaches `main` through one Dagger pipeline. The pipeline checks, reviews, fixes and merges each PR, and works each issue, without a person. The steady state is 0 open PRs and 0 open issues. The only exception is an item with the label `needs-human`, which holds one question that only a person can answer (see Decision Gates).

## Sources

- LEGO/devrel-infra: `.dagger/README.md`, `dagger.toml`, `.dagger/modules/ci/*.go` and `.github/workflows/*.yml`, read on 2026-10-30. The repository is internal.
- Dagger 1.0 beta: https://dagger.io/blog/dagger-10-beta/ (2026-10-23), https://dagger.io/changelog/cloud-checks and https://dagger.io/changelog/workspaces.
- den: `modules/M-02877/pr-reviewer.nix`, `.github/workflows/decapod-validate.yml`, `Justfile`, and the open issues and PRs.

## What devrel-infra Does

devrel-infra has one Go module, `.dagger/modules/ci`, which `dagger.toml` installs next to official modules (Go, golangci-lint, Staticcheck, Prettier, Playwright). `[modules.ci.settings]` holds the shared values, and `dagger.lock` pins each module. Its functions replaced the launchd pr-reviewer and auto-merger, which den still runs.

- **`ci automerge`.** `mergeRules` in `automerge.go` apply in order, and the first rule that fails gives the reason: open, not a draft, no `hold` or `do-not-merge` label, an allowed author, a review of the exact head commit by the reviewer login, no changes requested, no manual step in the description, the newest run of each check green, `MERGEABLE`, and no unresolved review thread. The merge sends the judged head commit as `sha`, so a push after the judgment makes GitHub refuse the merge. Without `--dry-run=false`, it only reports. `--replay` judges a merged PR as of its merge.
- **`ci reviewer`.** An LLM agent that uses the model gateway. It has one tool, `PostComment`. Go refuses every review event except `COMMENT`, so the agent cannot approve or request changes.
- **`ci fixer`.** The agent reads one failing check, edits the code, and runs the check again until it passes. It returns a patch. It never pushes. `fix-suggest.yml` posts the patch on the PR, and a person applies it.
- **`ci upgrader` and the Bump workflow.** Each night, Bump opens PRs for new base images, Dagger releases and project releases. When a release fails, the upgrader opens a draft PR with the label `hold`. Three jobs have different privileges: `find` (read token), `suggest` (only the gateway key) and `post` (write token, no secret, a path allowlist).
- **Engines.** A shared engine on AWS (`aws-dagger-engine`) runs CI jobs through an IAM role. A function that needs the model key runs on a local engine, because the shared engine never receives the key.
- **Triggers.** GitHub Actions workflows still start every function.

## What Dagger 1.0 Adds

- Workspaces: `dagger.toml` replaces `dagger.json`, and `dagger.lock` pins each module, image and source. `dagger workspace migrate` converts an old configuration.
- Official modules. The catalog has ShellCheck and Prettier. It has no Nix module.
- Test-native `dagger check`. `dagger check -i` opens a shell where a check failed.
- Remote engines, on your own hosts or on Dagger Cloud.
- Cloud Checks: `dagger cloud checks on` runs `dagger check` on Cloud Engines for each push and each PR, and reports GitHub check statuses. It needs no workflow file.

**The gap.** Cloud Checks runs checks only. Review, fix, merge, bump and issue work change GitHub state, and they need a write token and a model key. So they need a trigger of their own.

## Target Design

```
 push / PR / schedule
        |
        v
 +---------------+  statuses  +--------------------------------------------+
 | dagger check  | <--------- | ci shepherd (one pass every 2 min, systemd |
 | on den's own  | ---------> | timer on paphos; idempotent per head SHA)  |
 | engine        |            +--------------------------------------------+
 +---------------+                |         |           |           |
                                 v         v           v           v
                             reviewer    fixer     automerge     issues
                             (COMMENT)  (patch ->   (rules,     (triage or
                                         poster)    head SHA)    implement)
                                                       |
                                                       v
                                                     main ----> topgrade on M-02877:
                                                                git pull --ff-only,
                                                                just deploy-darwin
                                                                       |
                                                    deploy failure ----+--> new issue
```

den writes its own module, `.dagger/modules/ci`, in Go like devrel-infra. den is public, and devrel-infra and AEC are internal, so den cannot import their module.

1. **Checks** (`dagger check`):
   - `decapod-validate` in `ghcr.io/decapodlabs/decapod:v0.111.6-debian`, the image that `.decapod/managed/Dockerfile.decapod` pins. Local and CI runs then use the same binary, which closes the cache-key fragility.
   - `nix-eval`: `scripts/check-drvpaths.sh` in a Nix container, with a cache volume for `/nix`.
   - `fmt`: alejandra, as `just check-fmt` runs it.
   - `shellcheck`: the official module, for `scripts/*.sh`.
   - `decapod-overrides`: `just check-decapod-overrides`.
   - Not on a Linux engine: `check-doom-darwin` and every Darwin build. The deploy on M-02877 stays the build proof (item 7).
2. **Reviewer.** Port the pr-reviewer policy that den runs now: review rounds (`max_review_cycles = 2`), critical finding kinds, and stacked PRs (NicholaiVogel/pr-reviewer#32). Like devrel-infra, the reviewer posts `COMMENT` reviews only.
3. **Fixer that pushes.** This step goes past devrel-infra. For a PR from an allowed author, a failing check or a blocking review finding starts the fixer. The fixer makes a patch and runs the checks again in its sandbox. A separate poster job then pushes one commit to the PR branch. The poster refuses a patch that touches a denied path: `secrets/`, `secretspec.*`, `modules/_host-keys.nix`, `modules/_github-ssh-keys.nix`, `.decapod/OVERRIDE.md`, `terraform/`. After 3 fix rounds on one PR, the shepherd adds `needs-human`.
4. **Automerge.** Port den's `automergeFilter` (`modules/M-02877/pr-reviewer.nix`) and devrel-infra's `mergeRules`. Merge with the judged head SHA. Read the merge method from the repository settings.
5. **Bump** (nightly). Run `nix flake update` without the `darwin-skip-inputs`, and move the pins of the pi packages, Chorus, Signet, Headroom and Decapod to their newest releases. Each update is a PR that goes through items 1 to 4. When this works, topgrade on M-02877 stops `just update-darwin` and runs only `git pull --ff-only` and `just deploy-darwin`. That closes den#60.
6. **Issues.** For each open bead and GitHub issue without `needs-human`, the agent makes one of four decisions:
   - already fixed: close it, with the commit that fixed it;
   - a duplicate or superseded: close it, with a link;
   - work that it can do: open a work unit and a PR, which goes through items 1 to 4;
   - a decision: add `needs-human` and one question.
   Beads stays the tracker of record.
7. **Deploy report.** When a deploy on M-02877 fails, open one issue with the failing step and the end of the log. Do not open a second issue for the same failing step.

## Trust Boundaries

den is a public repository, so anyone can open an issue or a PR. Their text is untrusted input to an agent.

- The agent that reads issue or PR text gets no write token. A deterministic poster with a fixed path allowlist applies its patch. This is devrel-infra's `find`, `suggest` and `post` split.
- A PR from a fork, or from an author outside the allowlist, gets the checks only. No secret and no model key reach its runs. A person decides on it.
- The model key and the merge token are two Dagger secrets from a secret provider (`op://`, `file://` or similar). They never enter the repository or the Nix store (SECURITY.md, Credential Handling Invariant).
- Branch protection on `main` requires the Dagger check statuses. Only the merge identity merges.

## Decision Gates

A person answers each gate before the phase that needs it.

| Gate | Question | Options | Needed by |
|---|---|---|---|
| D1 | Which engine runs the checks and the shepherd, and who pays? | Cloud Checks on Dagger Cloud Engines (usage pricing, nothing to run); a self-hosted engine on paphos (no bill, den keeps it up); Cloud Checks for checks and paphos for the shepherd | P1 |
| D2 | Which model credential do the reviewer, the fixer and the issue agent use? | The LEGO AI Model Gateway key is a work credential, and den is a personal public repository. Today pr-reviewer uses a dedicated gateway virtual key on the work Mac. Options: keep model calls on a local engine on M-02877, as devrel-infra's fixer does; or use a personal provider key | P3 |
| D3 | Which identity merges? | Today automerge merges as the user's gh identity, because a `GITHUB_TOKEN` merge does not start runs on `main`. Options: a GitHub App, or a bot account that can only merge | P4 |
| D4 | How far does the agent go without a person? | The denied paths, the fix-round cap, the labels that stop automation, and the rule for outside contributors | P5 |
| D5 | Which Decapod readiness profile applies inside Dagger? | Local `validate` stops at `READINESS_PROFILE_REQUIRED` (den#61), and a CI-local run reports `publication_ready=false`. Set `proof.required_profile`, or accept the CI-local scope | P1 |
| D6 | Do den and AEC share one module? | A shared module must be public, because den is public. LEGO must approve before LEGO CI code becomes public. Otherwise den keeps its own module, with the same function names and rules as AEC | P1 |

### Decisions on 2026-10-30

The user answered D1, D2 and D6, and let the agent decide the rest. The user also set a standing rule: always upgrade everything to the latest release.

| Gate | Decision | Reason |
|---|---|---|
| D1 | den runs its own Dagger engine on paphos, and the shepherd runs next to it as a systemd timer. For each new head commit of `main` and of each open PR, the shepherd runs `dagger check` on that engine and posts the result as a GitHub commit status (`den/dagger-check`). No CI service and no GitHub Actions workflow is left. If paphos has too little memory for the Nix evaluation, oracle (aarch64-linux) is the second choice | Dagger Cloud is acceptable only on a free plan, and it has none: Starter costs $20 a month at minimum (https://dagger.io/pricing, read 2026-10-30). Cloud Checks needs Dagger Cloud. The team engine in LEGO/devrel-infra (`projects/aws-dagger-engine`) trusts GitHub OIDC tokens of `LEGO/devrel-infra` only, and it runs pull-request code, so it is not for a public personal repository. den already deploys paphos, with agenix secrets and Telegram alerts |
| D2 | The LEGO AI Model Gateway key | den is also used for work. The key is a Dagger secret from agenix on paphos, never in the repository or the store |
| D3 | A fine-grained token of `worldofgeese`, for `worldofgeese/den` only, with contents and pull-request write. A GitHub App with the same permissions can replace it later | The merge identity is the GitHub account that the merges come from. It needs write access, and GitHub records each merge under its name. A personal token needs no new setup. The shepherd finds each new head commit through the API, whatever the account that pushed it, so the identity does not decide which runs start. A GitHub App is a separate, narrower identity, but a person must create it in the GitHub settings |
| D4 | The denied paths, the 3-round cap and the trust boundaries in this plan. The labels `hold` and `needs-human` stop all automation. A PR from outside the allowlist gets checks only | The narrowest bounds that still let the agent fix its own PRs |
| D5 | Move den to the newest Decapod in its own PR, and pin the same release in CI and on PATH. Then decide the readiness profile with that release | The standing rule to use the latest release. One release everywhere removes den#61's pin rewrite |
| D6 | A public module, `.dagger/modules/ci` in den, with no company names, accounts, hosts or URLs in its code. Each repository gives those as settings in its own `dagger.toml`. AEC can install it at a pinned commit | A public module is acceptable when it holds no private or company information |

### Decisions on 2026-11-01

The user replaced the engine part of D1 and created the D3 token. The user also decided the update policy of the servers; TruePhoenix relayed that decision.

| Gate | Decision | Reason |
|---|---|---|
| D1 | The checks run on GitHub-hosted runners: `.github/workflows/dagger.yml`. The shepherd of P3 to P8 also runs as a workflow on these runners. No den host runs an engine for CI | Standard runners are free for a public repository, with no minute limit, and each job gets a new virtual machine. Dagger Cloud Checks (the Dagger GitHub app) costs at least 20 USD a month. Blacksmith works only for organizations, so den would move, and its free plan has fewer minutes. The Forgejo runner on loving-kypris takes jobs only from the Forgejo on paphos, runs one job at a time, and gives its jobs no privilege. A privileged engine there would run PR code in the same podman account as Vaultwarden and OpenClaw |
| D3 | The fine-grained token `den-shepherd` of `worldofgeese`, for `worldofgeese/den` only, for 366 days. It has write access to contents, pull requests, commit statuses and issues, and no workflows access. It is the secret `DEN_SHEPHERD_TOKEN` of the environment `shepherd`, and only jobs on `main` can read that environment | Without workflows access, GitHub refuses a push from the automation that changes a workflow file. A personal token cannot make check runs, so the shepherd writes commit statuses |
| Server updates | paphos and oracle keep `--override-input nixpkgs github:NixOS/nixpkgs/nixos-unstable`. P6 does not hold the servers to `flake.lock`. P8 reports the deployed den commit and nixpkgs revision of each server | The user wants the servers on the newest `nixos-unstable`. A green check of `flake.lock` does not prove the nixpkgs revision that a server fetches later, so the report names the revision that each server runs |
| P3 reviewer | The Codex connector stays den's reviewer. The shepherd (`dagger call ci shepherd`, `.github/workflows/shepherd.yml`) asks it to review each new head, and no model key is in den's CI. This replaces D2 for P3. P5 decides the model of the fixer. The review rules of den are in `modules/AGENTS.md` | The gateway key is a company credential, and den is a public personal repository. Codex already reviews each den PR with no key in CI. The root `AGENTS.md` is a Decapod template, and a hand edit fails validation |
| P4 start | The shepherd first only reports the merge verdict of each open PR. Live merges start after 10 PRs where the report agrees with the merge | The user agreed on 2026-11-01. The reports prove that the shepherd judges with its own token and runner as an agent does on M-02877 |

## Phases

Each phase is one bead under home-manager-1l3. Each phase ends with its proof.

| Phase | Work | Proof |
|---|---|---|
| P0 | Answer D1 to D6. Port the merge rules in dry-run mode, and judge den's last 30 merged PRs as of their merge, as `--replay` does. Close or rebase PRs #24 and #25 | A table of the merges that the rules accept and refuse, with a reason for each refusal |
| P1 | `dagger.toml`, `dagger.lock`, `.dagger/modules/ci` and the checks in item 1. Pin the engine image by digest, as devrel-infra pins `v1.0.0-beta.21@sha256:3444c48e...` | `dagger check` passes twice on M-02877, and the second run comes from the cache. A table maps each `just check` step to a Dagger check or a written exception |
| P2 | `dagger check` on GitHub-hosted runners (D1 as revised on 2026-11-01), the `den/dagger-check` check, and branch protection on `main` that requires it. The merge rules read `mergeStateStatus`. Delete `decapod-validate.yml` after 5 PRs where that check is required and green, and after a Dagger check validates the real change range of the PR. On 2026-11-01, 7 PRs passed, but `ci:decapod-validate` still sees an empty base, so the workflow stays (VALIDATION.md) | A PR shows the `den/dagger-check` check, and a failing check stops its merge |
| P3 | The shepherd asks the Codex connector to review each new head (Decisions on 2026-11-01). It waits 10 minutes on a new PR for the automatic review, asks at once for each later head, asks again after 20 minutes, and adds `needs-human` after 3 requests. No launchd job retires for den: `com.dktaohan.pr-reviewer` does not watch den | `ci:shepherd-rules` passes. On a live PR, the shepherd asks for a review of a head that has none. The code cannot send an `APPROVE` or `REQUEST_CHANGES` event |
| P4 | Automerge in the shepherd, in two steps. First, the shepherd reports the merge verdict of each open PR in its table, and merges nothing. Before each merge, an agent runs the workflow `shepherd` by hand and merges only a head that its report calls mergeable. Bead home-manager-1l3.5 counts the PRs where the report and the merge agree. After 10 PRs that agree, the shepherd merges by itself. No launchd job retires for den: `com.dktaohan.pr-reviewer-automerge` does not watch den | For 10 PRs, the report of the shepherd agrees with the merge. Then the live merges start |
| P5 | The fixer that pushes, and its poster. After each fix, the fixer replies to each finding with the fixing commit and resolves the thread | A test PR with a format error is fixed and merged without a person. A test PR that touches a denied path gets `needs-human` |
| P6 | The nightly bump of the pins in the repository: flake inputs, Dagger, Decapod, image digests and action commits. topgrade on M-02877 changed to pull and deploy only. In the same change, `scripts/deploy-freshness.sh` also refuses uncommitted edits; today it checks commits only, and a guard without the topgrade change stops each topgrade deploy. A bump PR that changes `flake.lock` also renews `reviewed_sources_digest` in `.decapod/config.toml`, because the readiness inventory includes the lock. The servers keep their own nixpkgs (Decisions on 2026-11-01) | A flake update PR merges. On M-02877, `scripts/deploy-freshness.sh` passes and the deployed commit is `origin/main`. den#60 is closed |
| P7 | The issue shepherd | For 7 days, no issue without `needs-human` is open. Each close names its evidence |
| P8 | The deploy report. For each host, it names the deployed den commit and nixpkgs revision, because paphos and oracle fetch `nixos-unstable` themselves | A forced deploy failure opens one issue, and a fix PR closes it |

## Open Items Today

| Item | State on 2026-10-30 | Where it goes |
|---|---|---|
| PR #24 (docs: guides lock-step) | closed: its rule landed in PR #69, with the current chain and pages | done |
| PR #25 (personal Signet 0.232.1) | closed: the pin is 0.238.0 (PR #68), and its fix for both lock paths landed in PR #69 | done |
| den#55 (context-mode twice) | closed by PR #68 | done |
| den#57 (Caveman shrinking) | waits for a Caveman CLI release with JuliusBrussee/caveman#1315 and #1321 | P6: the bump finds the release |
| den#59 (personal Signet scans) | open | P7 |
| den#60 (topgrade deploys an uncommitted lock) | open | P6 |
| den#61 (local Decapod validate) | closed by PR #67 (Decapod 0.121.1). On macOS, local readiness waits for DecapodLabs/decapod#1470 | D5 |
| PR #70 (ZenPhoenix: paphos and oracle) | open; it waits for the Tang enrollment on paphos by the user | merge after the enrollment |

### Progress

- **P0 (done).** D1 to D6 are answered, and #24 and #25 are closed. The merge rules are in `.dagger/modules/ci/automerge.go`: the automerge filter of `modules/M-02877/pr-reviewer.nix`, in its order, with the D4 stops. The fixture check `ci:automerge-rules` covers each rule. `ci:automerge-replay` judged the last 30 merges: 4 accepted, 26 refused, each with its reason (`docs/plans/2026-10-30-002-dagger-p0-merge-rule-replay.md`). One lesson for P4: a force-push changes the head, so the merger waits for a new review of the new head. The code is den's own, written from den's jq filter. devrel-infra's code is internal, so none of it is copied into this public module.
- **P1.** `.dagger/modules/ci` has the checks of item 1: `ci:nix-eval`, `ci:fmt`, `ci:shellcheck`, `ci:decapod-overrides` and `ci:decapod-validate`. The map from each `just check` step to a check, and the two limits, are in VALIDATION.md (Dagger Checks). Measured on M-02877 on 2026-10-30:
  - The default engine of the CLI does not start in Apple's container runtime (`/proc/sys/net/ipv4/ip_forward: read-only file system`). The podman VM's DNS does not answer AAAA queries for names without IPv6 records. `just dagger-check` makes a podman engine with a public resolver.
  - The cold run took 229 s. After the fixes, a run took 25 s, and `ci:nix-eval` took 23.5 s from the cache volume.
  - Item 1 named `ghcr.io/decapodlabs/decapod:v0.111.6-debian`. The checks read the image from `Dockerfile.decapod`, which is 0.121.1 today.
- **P4 (done).** Step 1 (#82) reported the verdict of the merge rules in the shepherd table. On 2026-11-02, after 10 pull requests where the report agreed with the merge (the last of them #95; bead home-manager-1l3.5 lists them all), step 2 gave the shepherd `--merge`. In each run it merges at most one accepted pull request, with `PUT /pulls/{n}/merge` and the `sha` of the judged head, so a later push to the same pull request cannot merge without a new verdict.
- **P6 (done).** The nightly bump of the flake inputs runs through a PR (#85, #88).
- **P8 (done).** The deploy report (#93, #95): `scripts/deploy-report.py` and the launchd agent `com.dktaohan.den-deploy-report` on M-02877.

## Metrics

- Open PRs without `hold`, and open issues without `needs-human`. The target is 0 for both.
- The median time from PR open to merge.
- Fix rounds per PR, and model tokens per PR.
- Dagger cost per day (Cloud Engines or the paphos engine).

## Risks

- **Dagger 1.0 is a beta.** Many CLI commands changed. Pin the engine image by digest and pin the CLI, and move both only through a bump PR.
- **A Linux engine cannot build Darwin.** It evaluates the Darwin configuration, but it cannot build it. The deploy on M-02877 stays the build proof. Checks that need a missing builder are skipped, as in `scripts/check-drvpaths.sh`.
- **The Nix store is large.** The first run is slow. A cache volume for `/nix` keeps the next runs short.
- **A fix and review loop can run without end.** Cap the rounds, judge each step on the head SHA, and make each step safe to run again.
- **Cost.** Set a token budget per PR and per day. At the budget, stop and add `needs-human`.
- **Prompt injection.** See Trust Boundaries.

## Coordination

IronUnion plans the same pipeline for LEGO/agentic-engineering-community, as a Chorus proposal. The two plans agree on the function names, the merge rules and the trust boundaries. D6 decides whether the two repositories share one module.

### Shared module interface (agreed with AEC on 2026-10-30)

AEC's plan is approved in Chorus: proposal `86ce0320-9afd-4b39-832e-f071b7654895` in the project "Agentic Engineering Community". AEC installs den's module at a pinned commit.

- **Two lanes.** PR code runs only on a PR engine that has no secret. Model calls run only on a credential engine that runs no PR code. The GitHub token stays in the shepherd process. Agents return data (findings, a patch, a decision), and the shepherd posts it after the denied-path check. den runs both engines on paphos. This refines D1: PR code cannot then poison a cache that a call with a credential reads later.
- **Settings.** The module takes these as settings in each repository's `dagger.toml`: `forkPolicy` (`checks-only` or `review-and-fix`), `authors`, `riskyPaths` (AEC adds maintainer approval), the `hold` and `needs-human` labels with a table from each refusal to its action, a deterministic bump rule, `statusPrefix`, phase flags, `prEngine` and `credentialEngine`. The module refuses by default: with no authors, nothing merges without a person. den's values are in its own `dagger.toml`. P0 adds `repository`, `authors`, `reviewer` and `riskyPaths`; the others come with the phases that use them.
- **Function names.** `shepherd`, `reviewer`, `fixer`, `automerge`, `bump` and `issues`.
- **Task M.** IronUnion opens a PR to den when P3 and P4 exist. Else, after two weeks, AEC keeps its own copy of the module.
