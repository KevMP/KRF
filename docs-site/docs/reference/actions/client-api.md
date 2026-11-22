---
title: ClientActionRuntime API
sidebar_label: Client API
---

# ClientActionRuntime API

`KRF.ClientActionRuntime` is a frozen client facade. All methods use dot syntax and require the lifetime installed by `KRF.Client.Init`.

## Direct requests

| Signature | Parameters and return value |
| --- | --- |
| `RequestAction(actor: ActorView, actionId: string, parameters: any?) -> (number?, string?)` | Requests Start with the full payload; returns a local request ID or nil/reason |
| `RequestStop(originalStartRequestId: number, parameters: any?) -> (number?, string?)` | Requests nonterminal Stop for the original Start; returns the follow-up's local ID |
| `RequestInterrupt(originalStartRequestId: number, reason: ActionInputInterruptReason) -> (number?, string?)` | Requests Interrupt for the original Start; returns the follow-up's local ID |
| `RetireRequest(originalStartRequestId: number) -> (boolean, string?)` | Locally releases follow-up authority; sends nothing and does not end server execution |

Direct calls bypass input policies and producers. Retain the original Start ID for follow-ups. A returned number means local admission, not server acceptance. Retiring an original preserves pending result correlation. An accepted Interrupt retires it automatically; accepted Stop is nonterminal.

`ActionInputInterruptReason` is `"RouteInvalidated"`, `"ContextDisabled"`, `"ActorSwitched"`, `"FocusLost"`, `"StopPreparationFailed"` or `"ClientShutdown"`.

## Shared request catalog

`KRF.ActionRequestSchemas` maps concrete Action IDs to:

| Field | Contract / default |
| --- | --- |
| `start` | Optional Schema for Start parameters; absent means parameterless |
| `stop` | Optional `{ parameters: SchemaDefinition? }`; absent disables Stop, `{}` enables parameterless Stop |
| `allowInputInterrupt` | Boolean, default false |
| `requiresClientRelease` | Boolean, default false; requires Stop, disconnect Interrupt and an explicit client WhileDown policy |
| `onDisconnect` | `"Keep"` (default) or `"Interrupt"` |

Supply the same catalog to server and client startup. Each Start carries a contract tag; the server rejects a mismatched contract with `ActionContractMismatch` when authorizing the request. Registering a contract is not an Action grant. Start and Stop payloads are bounded to 8,192 encoded bytes each.

## Profiles and Actor selection

| Signature | Behavior |
| --- | --- |
| `SetProfileSource(actor: ActorView, sourceId: string, profile: ControlProfile) -> (boolean, string?)` | Replaces the complete profile source for this Actor |
| `RemoveProfileSource(actor: ActorView, sourceId: string) -> (boolean, string?)` | Removes it; absent source succeeds |
| `SetControlledActor(actor: ActorView?) -> (boolean, string?)` | Selects the automatic routing target; nil clears it |
| `GetControlledActor() -> ActorView?` | Current available selection, or nil |
| `GetEffectiveRoute(actor: ActorView, key: RouteKey) -> RouteQuerySnapshot?` | Frozen inspection snapshot; does not invoke a resolver |
| `GetProfileSources(actor: ActorView) -> {ProfileSourceSnapshot}` | Frozen summaries `{ sourceId, priority, routeCount }`; empty when unavailable |

Mutations return `true, nil` on success; validation failure preserves the previous configuration. Actor arguments must be exact currently available registry identities. Switching Actor retires prior input ownership; a key already held cannot start a fresh press on the new Actor.

`ControlProfile` is `{ priority: number?, routes: {ActionRoute} }`. Priority defaults to `0` and must be an integer. The highest-priority source whose required contexts are enabled wins a route key; equal source priorities for one key fail even when a route is currently gated. An empty routes array removes the source. A source may have at most 256 routes, an Actor 32 sources, and the client 128 profiled Actors.

### RouteKey and ActionRoute

| Route key kind | Fields |
| --- | --- |
| `"Input"` | `inputId`, `gesture = "Pressed" \| "Tap" \| "Held" \| "LongHeld" \| "DoubleTapped"` |
| `"Sequence"` | `sequenceId` |
| `"Custom"` | `recognizerId` |

| `ActionRoute` field | Contract |
| --- | --- |
| `when` | RouteKey whose dependencies exist in the final input graph |
| `target` | `{ kind = "Fixed", actionId }` or `{ kind = "Dynamic", resolve = function(ctx) -> ResolvedAction? }` |
| `requiredContexts` | Optional array of existing context IDs that must be enabled |
| `dispatch` | Optional `{ mode = "Exclusive" \| "Independent", priority: number? }`; sequences default Exclusive, Input/Custom default Independent; priority defaults `0` |

Profile and dispatch priorities are integers in `[-2147483647, 2147483647]`. A route can require at most 16 distinct contexts (at most 64 authored entries before deduplication). Input routes require Bool inputs; gestures must be declared. At most 16 route intents may dispatch from one occurrence.

`ResolvedAction` is `{ actionId: string, parameters: any? }`. A resolver must not yield. Its read-only context contains `actor: ActorView`, `actorId`, `key: RouteKey`, `sourceId`, `timestamp`, and recognition `envelope` / `candidate` metadata. These describe the selected occurrence, not mutable native input instances. Nil declines selection; errors, yields or invalid results abort that selection without falling back to another route.

### RouteQuerySnapshot

| `status` | Fields |
| --- | --- |
| `"Mapped"` | `sourceId`, `priority`, `targetKind`, optional fixed `actionId`, `dispatchMode`, `dispatchPriority`, `requiredContexts`, `shadowedSources`, `version` |
| `"Gated"` | `candidateSources` |
| `"Unmapped"` | No additional fields |

The query returns nil for an invalid key, unavailable Actor or unready client. `version` identifies effective route continuity; do not use it as a network revision.

## Client input policies

`Client.Init({ actionInputPolicies = policies, ... })` captures a map of Action ID to `ActionInputPolicy`:

| Field | Contract / default |
| --- | --- |
| `activation` | `"OneShot"` (default), `"WhileDown"` or `"Toggle"` |
| `onInvalidation` | `"Interrupt"` by default for WhileDown; otherwise `"Keep"` |
| `startParameters(ctx)` | Optional synchronous full Start payload producer |
| `stopParameters(ctx)` | Optional synchronous full Stop payload producer; genuine release or Toggle-off only |

`ActionInputContext` contains `actor: ActorView`, `actionId`, optional `routeKey`, optional Start `resolvedParameters`, optional Stop `originalStartRequestId`, and optional verified `input` ownership `{ inputId, inputGeneration, pressEpochId, isActiveAfterCommit }`. Producers do not receive raw input events. Resolver parameters and producer results are never merged.

WhileDown and Toggle require a Stop contract. If that contract rejects nil, automatic Stop needs a `stopParameters` producer. Supplying a Stop producer or selecting Interrupt invalidation requires wire Interrupt permission. Invalid catalogs fail client startup under `system = "ActionInput"`; they are not repaired per input occurrence.

## Request observations

`OnActionRequest: Event<KRF.ActionRequestEvent>` reports immutable local facts. Every variant includes:

| Fields | Meaning |
| --- | --- |
| `actor`, `actionId` | Exact original ActorView and concrete Action |
| `originalStartRequestId`, `originalStartKey` | Original Start's local numeric ID and opaque correlation key |
| `origin` | `"Input"` or `"Direct"` for that original Start |
| `eventOrdinal`, `observedAt` | Increasing local fact order and monotonic observation time |

| `kind` | Additional fields |
| --- | --- |
| `"RequestAdmitted"` | `operation: "Start" \| "Stop" \| "Interrupt"`, `requestId`, `requestKey`, optional `inputOccurredAt` for input Start |
| `"RequestOutcome"` | `operation`, `requestId`, `requestKey`, `status: "Accepted" \| "Rejected" \| "Unknown"`, optional `reason`; `sequenceId` only for Accepted Start |
| `"InputTransition"` | `transition: "GenuineRelease" \| "ToggleOff" \| "InvalidatedInterrupt" \| "InvalidatedKeep"`, optional `reason` |

Local refusal emits no admission. A send failure after admission can produce Unknown. Follow-ups have their own request IDs while retaining the original identity. Keys are correlation data, not wire credentials. Callbacks can run out of order; preserve `eventOrdinal` when processing facts asynchronously. [Request lifecycle](./requests) explains uncertainty and visible Action state.

## Failures

| Reasons | Cause |
| --- | --- |
| `ClientNotReady`, `DispatchInProgress` | Unavailable lifetime or protected transition |
| `ActorViewUnavailable`, `ActionRequestUnregistered` | Invalid current Actor identity or absent wire contract |
| `ActionRequestCapacityReached` | Local Action request budget reached; Command capacity failures can also apply |
| `ActionPayloadUnexpected`, `ActionPayloadInvalid`, `ActionPayloadTooLarge` | Parameters violate the declared schema or size bound |
| `ActionStartUnknown` | Original Start is unknown, retired or from another client lifetime |
| `ActionStopUnavailable` | No Stop contract |
| `ActionInterruptNotAllowed`, `ActionInterruptReasonInvalid` | Interrupt lacks permission or uses an unsupported reason |
| `ActionInputRequestInProgress` | Nested manual follow-up during preparation of that automatic activation |
| `InvalidProfileSourceId`, `InvalidControlProfile`, `InvalidProfilePriority` | Invalid source/profile shape |
| `InvalidActionRoute`, `InvalidRouteKey`, `InvalidRouteTarget`, `InvalidActionId`, `DuplicateRouteKey` | Invalid or duplicate route |
| `UnknownRouteInput`, `RouteInputNotBool`, `UnknownRouteGesture`, `UnknownRouteSequence`, `UnknownRouteRecognizer`, `UnknownRouteContext` | A supplied route references an invalid dependency |
| `InvalidRequiredContexts`, `InvalidDispatchPolicy` | Invalid gating/dispatch fields |
| `ProfilePriorityConflict`, `ProfileDependencyMissing` | Conflicting source priority or missing input dependency |
| `ProfileRouteLimitExceeded`, `RouteContextLimitExceeded`, `ProfileSourceLimitExceeded`, `ProfileActorLimitExceeded` | Profile budget exceeded |
| `StaleActorSwitch`, `ActorSwitchGuardFailed`, `ActorSwitchGuardYielded`, `ActorSwitchCommitFailed` | Actor selection could not complete |

These are local failures. Server outcomes can separately reject [Action admission](./api) or the request protocol:

| Server reason | Cause |
| --- | --- |
| `ActorNotOwned` | The requester does not control the Start target |
| `ActionContractMismatch` | Client and server disagree about that Action's request contract |
| `ActionControllerUnavailable` | The target has no ActionController |
| `ActionReceiptCapacityReached`, `ActionReceiptGlobalCapacityReached` | Server receipt capacity is exhausted |
| `ActionReceiptUnknown` | A follow-up no longer has a live original activation on that connection |
| `ActionStopAlreadyDelivered` | The original Start has already delivered its one wire Stop |
| `ActionRequestConnectionClosed` | Connection lifetime ended before Start could commit |

Use [ClientControls](../controls/api) when input and profile dependencies must change together.

### Startup contract failures

| Reasons | Cause |
| --- | --- |
| `ActionRequestSchemasMustBeTable`, `ActionRequestSchemaMustBeTable` | Invalid shared catalog or entry |
| `ActionRequestIdInvalid`, `ActionRequestIdTooLong` | Invalid Action ID or more than 96 bytes |
| `ActionRequestFieldUnknown`, `ActionRequestStopInvalid`, `ActionRequestFlagInvalid` | Unknown field, invalid Stop record or non-boolean flag |
| `ActionRequestDisconnectPolicyInvalid` | Unsupported disconnect policy |
| `ActionRequestUnknownAction` | Server request catalog names an unregistered Action |
| `ActionRequestReleaseRequiresStop`, `ActionRequestReleaseRequiresDisconnectInterrupt` | Incomplete release-required contract |
| `ActionRequestPayloadTooLarge` | Start or Stop schema exceeds its conservative payload budget |
| `ActionInputPoliciesInvalid`, `ActionInputPolicyInvalid`, `ActionInputPolicyLimitExceeded` | Invalid client catalog/entry or more than 4,096 policies |
| `ActionInputPolicyUnknownAction`, `ActionInputPolicyFieldUnknown`, `ActionInputProducerInvalid` | Unknown Action, field or non-function producer |
| `ActionInputActivationInvalid`, `ActionInputInvalidationInvalid` | Unsupported policy choice |
| `ActionInputReleasePolicyRequired`, `ActionInputStopRequired`, `ActionInputStopProducerRequired`, `ActionInputInterruptRequired` | Policy cannot satisfy the shared release/Stop/Interrupt contract |

Schema-definition failures also propagate. Shared contract validation reports `system = "ActionRequest"`; client policy validation reports `system = "ActionInput"`.
