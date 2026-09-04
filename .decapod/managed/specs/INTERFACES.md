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
- Source-of-truth tables/collections:
- Cross-boundary read models:
- Consistency expectations:

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
| Human CLI | | | | | |
| JSON/automation | | | | | |
| RPC/plugin | | | | | |
| Event/file boundary | | | | | |

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

<!-- decapod:codebase-attestation:start -->

## Codebase Attestation

- Repository signal fingerprint: `be0a0a0a240af03eda9eb65faaecf3abce3e08efc4a3da8bac3caa4f1dede8f4`
- Significant implementation surfaces: `.beads/` (1 files), `README.md/` (1 files), `docs/` (2 files), `terraform/` (1 files)
- Refreshed from the current codebase by `decapod specs.refresh`
<!-- decapod:codebase-attestation:end -->
