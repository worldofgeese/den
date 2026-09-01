# Semantics

## State Machines
```mermaid
stateDiagram-v2
  [*] --> Draft
  Draft --> InProgress
  InProgress --> Verified
  InProgress --> Blocked
  Blocked --> InProgress
  Verified --> [*]
```

## Invariants
| Invariant | Type | Validation |
|---|---|---|
| No promoted change without proof | System | validation gate |
| Canonical source-of-truth per entity | Data | interface/spec review |
| Mutation events are replayable | Data | deterministic replay |

## Event Sourcing Schema
| Field | Type | Description |
|---|---|---|
| event_id | string | globally unique event id |
| aggregate_id | string | entity/workflow id |
| event_type | string | semantic transition |
| payload | object | transition data |
| recorded_at | timestamp | append time |

## Replay Semantics
- Replay order:
- Conflict resolution:
- Snapshot cadence:
- Determinism proof strategy:

## Error Code Semantics
- Namespace:
- Stable compatibility window:
- Mapping to retry/degrade behavior:

## Domain Rules
- Business rule 1:
- Business rule 2:
- Business rule 3:

## Idempotency Contracts
| Operation | Idempotency Key | Duplicate Behavior |
|---|---|---|
| create/update mutation | request_id | return original result |
| async enqueue | event_id | ignore duplicate enqueue |

## Transition Contract
| Current State | Trigger | Preconditions | State Mutation | Emitted Evidence | Next State |
|---|---|---|---|---|---|
| | | | | | |

## Invariant Violation Response
- Which invariant is checked before mutation?
- Which invariant is checked after persistence?
- Is the failed operation retried, rejected, compensated, or escalated?
- What evidence distinguishes a rejected operation from an incomplete one?
- Which state remains canonical if derived state disagrees?

## Determinism and Replay Boundary
- Inputs included in a replay:
- Inputs deliberately excluded (wall clock, randomness, external state):
- Ordering and conflict resolution:
- Snapshot/checkpoint policy:
- Proof that replay is equivalent to the original outcome:

## Backward-Compatibility Semantics
- Legacy states accepted:
- Legacy states rewritten:
- States that require a migration:
- Agent instruction emitted before a breaking transition:
- Rollback behavior if migration or replay fails:

## Language Note
- Primary language inferred: shell

<!-- decapod:capability-overlay:persistent-state:start -->

## Persistent State Semantics Overlay

### Transaction Semantics
- All multi-entity operations MUST be atomic
- Read-after-write consistency within transaction boundaries
- Eventual consistency windows MUST be documented

### Migration Semantics
- Schema migrations MUST be backward-compatible
- Migration rollback procedures MUST be documented
- Data integrity checks post-migration

### Recovery Semantics
- Point-in-time recovery capability
- Recovery objectives MUST be selected for the project and recorded as proof obligations
- Recovery test cadence MUST be selected for the project and recorded as a proof obligation
<!-- decapod:capability-overlay:persistent-state:end -->

