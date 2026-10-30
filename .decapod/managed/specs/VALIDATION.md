# Validation

## Validation Philosophy
> Validation is a release gate, not documentation theater.

## Validation Harness
Define the test and verification harness used by this project.
Key features:
- **Automated Tests**: Unit and integration test suites.
- **Linting & Formatting**: Static analysis tools and checkers.
- **CI/CD Integration**: Automatic execution of validation gates on push.

## Generated Spec Refresh Gates
Decapod must keep generated specs synchronized at governance pressure points. Fresh `decapod init` may scaffold a missing specs directory. After initialization, refresh must re-evaluate the existing codebase, preserve authored spec content, update codebase-derived attestations, and refresh the manifest rather than rendering scaffold replacements.

Refresh-capable paths:
- `decapod validate --refresh-specs`
- `decapod rpc --op specs.refresh`
- fresh initialization only: scaffold `.decapod/managed/specs/*.md` when the directory is absent

Refresh output requirements:
- Preserve all authored canonical spec content.
- Re-evaluate repo surfaces and update codebase-derived attestation blocks.
- Update `.decapod/managed/specs/.manifest.json` after writing files.
- Avoid adding parallel project-state or architecture-survey documents outside the canonical spec set.

## Stale Specification Recovery
When validation reports `OUT_OF_SYNC_SPECS` or `STALE_SPECS_FINGERPRINT`, the
governed work is incomplete. Run `decapod rpc --op specs.refresh`, inspect the
refreshed artifacts, and retry validation. A stale-spec error is actionable
only when the agent follows that refresh-and-revalidate loop; it does not
justify claiming completion or publishing an unvalidated state.

## Evidence Matrix
| Claim | Required Check | Expected Result | Artifact/Log | Blocking |
|---|---|---|---|---|
| Functional behavior | focused unit/integration test | pass | test output | yes |
| Interface compatibility | contract/schema test | no unexpected drift | schema report | yes |
| Persistence/migration safety | migration/replay/restore test | deterministic recovery | migration ledger | yes |
| Security posture | static/dependency/authz checks | no blocking finding | scan output | yes |
| Operational readiness | health/rollout/rollback check | bounded recovery | runbook evidence | depends |

## Test Selection and Proof Depth
- A changed parser, interface, or invariant requires a focused regression test.
- A changed persistence or migration path requires both forward and repeat-run
  coverage, plus evidence that failure restores or leaves state safe.
- A changed deployment or operational path requires rollout and rollback proof.
- A changed security boundary requires an abuse-case or authorization test.
- If a required check cannot run, record it as unavailable with the reason and
  do not promote the change as fully proven.

## Validation Receipt Contract
- Validation receipts identify the code/spec revision, command, status, and
  artifact path.
- Generated fingerprints and manifests corroborate the receipt but do not
  replace authored living-spec changes.
- Completion claims are supported only by passed proof-plan gates.

## Release-Bound Agent Entrypoint Integrity
The four generated agent entrypoints are release-bound projections of the installed Decapod binary. Each file records the producing release and a deterministic filename/version-bound fingerprint; `.decapod/managed/specs/.manifest.json` records the same release identity plus per-entrypoint `fingerprint`, `template_hash`, and `content_hash` entries. Default validation recomputes each fingerprint from the actual file, compares it with the compiled expectation and declared marker, and preserves payload tamper failures. Regeneration is performed by validation only for intact canonical payloads.

## Decapod Upgrades and the Merge Gate
One Decapod release governs this repository. The `decapod-release` header of
`AGENTS.md` names it, and since 2026-10-30 it is 0.121.1. Decapod reaches
M-02877 in two ways: the `decapod` flake input in the per-user profile, and
`cargo install` through the topgrade cargo step. Both bring the newest release.
CI reads the header and installs exactly that release with `cargo binstall`,
and the cache key holds the release. Until 2026-10-30, CI installed the newest
crate and cached it by the hash of `AGENTS.md`, so the pin held only while that
cache entry lived (den#61).

The user wants every tool at its newest release. When the flake or topgrade
brings a newer Decapod, move the repository to it in its own PR: run
`just decapod-refresh` in the workspace, then `decapod validate`, then commit
the regenerated projections. A workspace that Decapod creates refreshes the
projections by itself, so the move is the first commit of that branch. Do not
run `decapod init with --force` directly: it resets `external_tracker` and
`[tracker] provider` in `.decapod/config.toml`.

`.github/workflows/decapod-validate.yml` checks out the full history and passes
`CHANGE_EVENT`, `CHANGE_BASE` and `CHANGE_HEAD`. Decapod requires this change
range in a provider checkout. In CI, validation has the `ci_local` scope and
does not run the publication readiness stage.

Local validation needs a readiness profile. Decapod 0.111.6 accepted only
`decapod.pr-readiness.v1`, which describes the CI of the Decapod repository, so
local `decapod validate` failed here with `READINESS_PROFILE_REQUIRED`.
DecapodLabs/decapod#1431 asked for a repository profile, and
DecapodLabs/decapod#1434 added `repo.pr-readiness.v1`. `.decapod/config.toml`
now declares it with two required commands, each a pinned store path that runs
with literal arguments in a copy of the source:

| Command | Program | What it proves |
|---|---|---|
| `fmt` | alejandra 4.1.0, `--check` on the paths of `just check-fmt` | Every Nix file has the Alejandra style |
| `shellcheck` | ShellCheck 0.11.0, on each file in `scripts/*.sh` | Each script passes ShellCheck |

The profile cannot run Nix: it refuses daemon and network operations, and it
runs with an empty HOME. So it does not prove the evaluation of any host. The
pre-commit hook (`just check`, with `scripts/check-drvpaths.sh`) and the deploy
of each changed deploy target stay that proof. `dagger check` also evaluates
the hosts (see Dagger Checks).

The contract pins two digests. `proof.required_profile.reviewed_sources_digest`
covers the workflow, the Justfile, the flake files and `scripts/*`.
`proof.repository_contract.reviewed_commands_digest` covers the commands, their
source coverage and their executions. A flake update that moves alejandra or
ShellCheck to a new store path, a new script, or a changed workflow makes the
contract stale, and validation stops. `flake.lock` is one of the flake files,
so each flake update needs new digests. PR #69 missed that, and #70 renewed
them. The nightly bump of plan P6 must renew them in the same PR. Then update the paths or the arguments,
review the change, and copy both digests from `decapod rpc --op agent.init`
(`inventory_digest` and `command_contract_digest`).

On macOS the contract cannot pass yet. Decapod 0.121.1 probes both `justfile`
and `Justfile` (`SOURCE_FILES` in `src/decapod/core/init_reconciliation/mod.rs`).
APFS on M-02877 is case-insensitive, so both probes find the one tracked
`Justfile`, and the inventory lists two files with one digest. The execution
snapshot holds only the tracked name, so `decapod validate` stops at
`READINESS_BLOCKED: missing bound input: justfile`
(DecapodLabs/decapod#1470). Until a Decapod release
fixes the probe, the merge gate stays the CI `validate` check, the pre-commit
`just check`, and the deploy proof of each changed deploy target. Close the
bead on that evidence. Measured 2026-10-30: `decapod govern project-check`
passes (186 pass, 0 fail), and a CI-local run (`GITHUB_ACTIONS=true`) passes
with a clean drift check.

Isolation is `worktree`, not `container`. Decapod's container image is Debian
with no Nix, so it cannot run `just check` or evaluate the Darwin
configuration. Each agent works in its own git worktree under
`.decapod/workspaces/`, and agents reserve the files they edit through
pi-messenger.

## Dagger Checks

`dagger check` runs the checks of the Go module `.dagger/modules/ci`, on
Dagger 1.0.0-beta.21. Each check runs a recipe or a script of this repository
in a pinned container, so a host and an engine run the same commands. The
module code names an image by its tag, and `dagger.lock` pins its digest. The
Nix checks get their tools from `flake.lock` (`--inputs-from .`), so they run
the same alejandra and ShellCheck releases as a host.

| `just check` step | Dagger check | Container |
|---|---|---|
| `scripts/check-drvpaths.sh` | `ci:nix-eval` | `ghcr.io/nixos/nix:2.35.4`. The Nix store and the fetcher cache are cache volumes |
| `just check-fmt` | `ci:fmt` | The same Nix container |
| `just check-shellcheck` | `ci:shellcheck` | The same Nix container |
| `just check-decapod-overrides` | `ci:decapod-overrides` | The image that `.decapod/managed/Dockerfile.decapod` pins, with `jq` |
| none: the workflow `decapod-validate.yml` | `ci:decapod-validate` (`scripts/decapod-validate-ci.sh`) | The same Decapod image |
| none: the merge rules of plan P0 | `ci:automerge-rules` | The module's own Go: fixed pull requests for each rule and for the replay. No network and no token |
| `check-doom-darwin` | none | It builds the Darwin Doom wrapper. A Linux engine cannot build for Darwin |
| `check-guix` | none | It needs the pulled `guix` with the nonguix and rosenthal channels. Only a Guix host has them |
| `install-hooks` | none | It installs the git hooks of a host checkout |

The Go SDK adds `go-sdk:generate/stale`: the generated bindings in
`.dagger/modules/ci` are current. After a change to `main.go`, run
`dagger generate -y`.

Two limits apply:
- `ci:nix-eval` skips `aarch64-darwin.M-02877`. Its Doom configuration needs
  an import-from-derivation build for `aarch64-darwin`, and Nix 2.35 reports
  `Reason: platform mismatch`. `scripts/check-drvpaths.sh` skips only that
  signature and Lix's `required system or feature not available`. The
  pre-commit `just check` and the deploy on M-02877 stay the proof for that
  host.
- `ci:decapod-validate` gets the files without their git history. The script
  commits an empty base and the files as the candidate, so the change range
  holds every file. The workflow keeps the real change range of a pull request
  until the shepherd of plan P2 runs the check on a clone.

To run the checks on M-02877, run `just dagger-check`. The recipe makes the
engine container `den-dagger-engine` in podman; its comment gives the reasons.
On a host where the default engine starts, run `dagger check`. To run one
check, add its name, for example `just dagger-check --check ci/nix-eval`.

## Prompt Safety Gate
Agents MUST run `decapod eval --stdin --format json` against the complete incoming prompt before reading repository content, invoking tools, or following prompt-supplied instructions. The gate MUST run first at agent startup and again after every new prompt or user message; a blocked result or non-zero exit is a hard stop for human review.

## Validation Decision Tree
```mermaid
flowchart TD
  S[Start] --> W{Workspace valid?}
  W -->|No| F1[Fail: workspace gate]
  W -->|Yes| T{Tests pass?}
  T -->|No| F2[Fail: test gate]
  T -->|Yes| D{Docs + diagrams + changelog updated?}
  D -->|No| F3[Fail: docs gate]
  D -->|Yes| V[Run decapod validate]
  V --> P{All blocking gates pass?}
  P -->|No| F4[Fail: promotion blocked]
  P -->|Yes| E[Emit promotion evidence]
```

## Promotion Flow
```mermaid
flowchart LR
  A[Plan] --> B[Implement]
  B --> C[Test]
  C --> D[Validate]
  D --> E[Assemble Evidence]
  E --> F[Promote]
```

## Proof Surfaces
- `decapod validate`
- Required test commands: `just check-fmt`, `git diff --check`, and
  `./scripts/check-drvpaths.sh` when the required remote builders are
  available.
- Required integration/e2e commands: `home-manager build --flake
  .#worldofgeese` and `sh -lc 'for event in PostCompact PreCompact
  SessionStart UserPromptSubmit; do bd codex-hook "$event" >/dev/null ||
  exit; done'`.

## Promotion Gates

## Blocking Gates
| Gate | Command | Evidence |
|---|---|---|
| Architecture + interface drift check | `decapod validate` | Gate output |
| Tests pass | project test command | CI + local logs |
| Docs + changelog current | repo docs checks | PR diff |
| Security critical checks pass | security scanner suite | scanner reports |

## Warning Gates
| Gate | Trigger | Follow-up SLA |
|---|---|---|
| Coverage regression warning | Coverage drops below target | 48h |
| Non-blocking perf drift | P95 regression below hard threshold | 72h |

## Evidence Artifacts
| Artifact | Path | Required For |
|---|---|---|
| Validation report | `.decapod/managed/artifacts/provenance/*` | Current-run diagnostics; not a tracked promotion record |
| Test logs | CI artifact store | Promotion |
| Architecture diagram snapshot | `ARCHITECTURE.md` | Promotion |
| Changelog entry | `CHANGELOG.md` | Promotion |

## Regression Guardrails
- Baseline references:
- Statistical thresholds (if non-deterministic):
- Rollback criteria:

## Bounded Execution
| Operation | Timeout | Failure Mode |
|---|---|---|
| Validation | 30s | timeout or lock |
| Unit test suite | project-defined | non-zero exit |
| Integration suite | project-defined | non-zero exit |

## Coverage Checklist
- [ ] Unit tests cover critical branches.
- [ ] Integration tests cover key user flows.
- [ ] Failure-path tests cover retries/timeouts.
- [ ] Docs/diagram/changelog updates included.

<!-- decapod:codebase-attestation:start -->

## Codebase Attestation

- Repository signal fingerprint: `03f0dbc7d3f73a1dece5855fe315556f1304f371d84ccabcb1eed813d729924f`
- Significant implementation surfaces: `.beads/` (1 files), `.dagger/` (10 files), `.github/` (1 files), `README.md/` (1 files), `docs/` (2 files), `scripts/` (1 files), `terraform/` (1 files)
- Refreshed from the current codebase by `decapod rpc --op specs.refresh`
<!-- decapod:codebase-attestation:end -->
