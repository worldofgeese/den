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
Decapod reaches M-02877 in two ways: the `decapod` flake input in the per-user
profile, and `cargo install` through the topgrade cargo step. CI installs the
latest crate with `cargo binstall`. Thus one topgrade run can change the Decapod
release that governs this repository.

After a Decapod upgrade, run `just decapod-refresh` in the workspace, then run
`decapod validate`, then commit the regenerated projections. Do not run
`decapod init with --force` directly: it resets `external_tracker` and
`[tracker] provider` in `.decapod/config.toml`.

`.github/workflows/decapod-validate.yml` checks out the full history and passes
`CHANGE_EVENT`, `CHANGE_BASE` and `CHANGE_HEAD`. Decapod 0.111 requires this
change range in a provider checkout. In CI, validation has the `ci_local` scope
and does not run the publication readiness stage.

Decapod 0.111.6 local validation requires `[proof.required_profile]`. The only
profile is `decapod.pr-readiness.v1`, and its ID is fixed in the binary. That
profile describes the CI of the Decapod repository and its Buildkite proof. Thus
local `decapod validate` and `decapod todo done --validated` fail here with
`READINESS_PROFILE_REQUIRED`. Do not declare that profile, because it does not
describe this repository. Until Decapod supports a profile for this repository,
the merge gate is the CI `validate` check plus the deploy proof of each changed
deploy target. Close the bead on that evidence, and release the work unit with
`decapod todo release`.

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

- Repository signal fingerprint: `2758b2391db7ef1bd2a4bf29226f0e08be54c479b189037e5da2efa26e7e0a05`
- Significant implementation surfaces: `.beads/` (1 files), `.github/` (1 files), `README.md/` (1 files), `docs/` (2 files), `scripts/` (1 files), `terraform/` (1 files)
- Refreshed from the current codebase by `decapod rpc --op specs.refresh`
<!-- decapod:codebase-attestation:end -->
