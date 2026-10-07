---
sidebar_position: 10
---

# Advanced Ordering & Reentrancy

This page is the canonical Action transaction and nested-callback contract. Ordinary gameplay code should rely on committed state before callbacks and use current getters; read this page when writing listeners or decisions that synchronously call back into KRF.

## Request planning {#request-planning}

A request follows this sequence:

1. Check controller/Actor availability, Action identity, registry membership, effective grant, Tag requirements, Resource requirements, and affordability.
2. Call the request factory and capture its callbacks. Call `onCanStart`, if defined.
3. Recheck controller/Actor availability and grant. Resolve requested lifetime-lock conflicts against the current owners; each owner must permit the incoming id through `interruptibleBy` and optional `canBeInterruptedBy`.
4. Revalidate availability, grants, and Tags; validate declarative Tag applications and build a fresh final Resource plan.
5. Commit without intervening consumer work or yielding.

Preflight rejects obvious failures before request factory work. Decision callbacks may change state or perform nested requests; the final plan therefore uses current state after those decisions. All Resource requirements and costs are evaluated against pre-spend values. Requirements cannot be rescued by planned owner cleanup or incoming Tags.

A request rejection commits no incoming activation, prepared payment, planned preemption, incoming lock claims, or declarative effects. It allocates no sequence id. Explicit mutations made by game callbacks are independent committed work and are not rolled back.

## Acceptance commit {#acceptance-commit}

The authoritative commit:

1. Pays all prepared costs at their fixed final-plan price.
2. Makes all preempted owners inactive and releases their locks/update membership, retires suspended starts, and removes their remaining Action-owned active Tag contributions.
3. Applies incoming `activeTags`, then `appliedTags`, in declaration order; activates the incoming instance, assigns its sequence id, acquires its lifetime locks, and registers optional updates.
4. Resolves final Tag-derived Properties and affected Resource state before callbacks.

The static catalog supplies metadata; the request factory supplies only callbacks. Sequence ids follow actual commit order, so a request nested during an outer decision can receive an earlier id.

Tags removed from owners and added by the incoming activation resolve as one final derived-state change. Equivalent replacement modifiers do not cause intermediate clamping or fake Property/Resource notifications. Each affected Resource recomputes once from final Properties; valid bounds clamp the already-paid current value.

Same-transaction Tag/Property effects cannot re-price the incoming Action. Invalid final bounds or non-finite derived min/max/regen preserve the Resource's last valid min/max/regen state, including committed current-value mutations. The Action remains accepted, its payment remains committed, and KRF does not repair the range. No terminal path automatically refunds costs.

## Normal post-commit dispatch {#post-commit-dispatch}

For acceptance with preempted owners, the normal signal/hook issuance order is:

```text
preempted owners' OnActionInterrupted, ascending sequence id
incoming OnActionStarted
resulting Tag events, mutation order
Property notifications, commit order
Resource notifications, Resource-id order within this transaction
preempted owners' onInterrupt, ascending sequence id
incoming onStart, only if still active
```

Each Tag event uses ordinary Tag Runtime event pairs. Within a Property transition, applicable base and resolved signals precede the combined Property signal. Unchanged resolved values do not emit resolved changes.

This describes normal issuance order, not a barrier requiring every signal listener to finish. Listeners may yield; hooks need not wait for their completion. Synchronous reentry can dispatch pending notifications before the remaining outer phases, as described below.

## Terminal, claim, and destruction commits

End/Interrupt first commits inactivity, all lock releases, update removal, suspended-start retirement, and remaining active Tag cleanup, including final derived state. Normal dispatch then issues the matching terminal lifecycle signal, Tag events, Property notifications, Resource notifications, and terminal hook. Inside that hook, `ctx:IsActive()` is false. `appliedTags` survive under ordinary Tag rules.

A scoped claim uses its active claimant's id and original start parameters for interruption decisions. It commits all approved owner interruptions and every requested claim before callbacks. Normal dispatch issues owners' Interrupted signals in sequence order, cleanup Tag/Property/Resource notifications, then owners' interruption hooks in sequence order. The claimant has no new Started event. Release removes only that claim's ownership reason; terminal cleanup removes all reasons.

Destruction makes every active activation inactive before any teardown callback, then issues Interrupted signals in sequence order, cleanup/derived notifications, and interruption hooks in sequence order. Public Action mutations during teardown reject with `ActionControllerDestroyed`. Failures in terminal hooks are contained and cannot prevent other activations from being cleaned up.

## Synchronous reentry {#synchronous-reentry}

Nested `RequestAction`, `EndAction`, and `InterruptAction` calls complete their own synchronous work before returning; they are not deferred behind the outer dispatch. Getters read the latest committed state, which an earlier callback may already have changed. Event payloads describe their committed transition, not necessarily the current state.

Started is issued exactly once for every accepted activation and before its terminal signal. If an earlier owner's lifecycle listener terminates the incoming activation before its normal Started turn, KRF issues its pending Started before issuing its terminal signal. The outer request still returns the accepted sequence id; `onStart` is skipped if the activation is already inactive.

Likewise, a successful `ClaimLocks` may return after an owner callback has terminated the claimant. Success means the claim crossed its acquisition commit, not that the claimant remains active. Recheck `IsActive` after calls that can invoke consumers.

### Decision-plan changes

Distinct conflicting owners are evaluated in ascending sequence-id order. If a decision changes ownership of the requested locks, KRF rebuilds the conflict plan and may call owner decisions again. Unrelated Action changes leave it valid. Conflict resolution is bounded to 64 attempts; an unstable plan rejects as a lock conflict. Write decision hooks as non-yielding observations rather than using them to orchestrate gameplay mutations.

### Pending Property and Resource notifications

Property notifications are journaled in commit order. A lifecycle or Tag listener that performs a mutation dispatching Properties can drain older pending Property notifications before the remaining outer phases. Recursive drains issue each notification once and place newer transitions after older ones.

Within an authoritative/batched transaction, each affected Resource publishes at most one net transition, sorted by Resource id. No event is emitted if current/min/max are unchanged; regen-only changes do not emit a Resource change. Across transactions, all older pending Resource notifications issue before newer nested ones, even if a newer Resource id sorts earlier. Nested Resource mutations remain synchronous and issue their required notifications before returning.

Property listeners can already read final Resource state. A payload may report an older cost or bound transition while getters reflect a newer nested mutation. Avoid treating payload values as a read lock on current state.

Destroying a Tag, Property, or Resource controller can suppress its remaining pending notifications. Property notification groups already begun finish their group; unstarted groups are discarded. Resource destruction discards pending changes. These teardown effects do not undo an accepted Action's committed transition.

## Update passes {#update-passes}

KRF snapshots all update-eligible activations across Actors before the first callback of a pass. Within one Actor, callbacks run in ascending sequence-id order; no cross-Actor order is promised. It checks that each captured activation remains update-enabled immediately before invocation.

An Action started during a pass waits until a later pass, even when started on a different Actor. Ended, Interrupted, or destroyed activations are skipped before their turn. Each delta is sampled immediately before that activation's callback, and only finite positive deltas are dispatched. Start and terminal hooks observe already-committed update membership.

Related: [Action Lifecycle](./action-lifecycle), [Action Resources](./action-resources), [Locks & Preemption](./action-locks), [Property changes](../Property/property-runtime#changes), [Resource notifications](../Resource/resource-runtime#notifications), [public reference](/api/Action/action-controller).
