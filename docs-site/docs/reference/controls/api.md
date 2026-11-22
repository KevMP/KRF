---
title: ClientControls API
sidebar_label: API
---

# ClientControls API

`KRF.ClientControls` is a frozen facade installed by `KRF.Client.Init`.

```lua
KRF.ClientControls.Apply(changeSet: KRF.ControlChangeSet) -> (boolean, string?)
```

Returns `true, nil` after successful local publication, including empty or equivalent changes. Returns `false, reason` on failure.

The call is synchronous. Unlike individual InputRuntime mutations, it does not queue the batch when input delivery or a protected transition is already in progress; it returns `DispatchInProgress`. Success does not wait for deferred public listeners or server acknowledgements.

## ControlChangeSet

| Optional field | Dense array of operations / value |
| --- | --- |
| `inputs` | `{ kind = "Set", sourceId: string, definition: InputSourceDefinition }` or `{ kind = "Remove", sourceId: string }` |
| `profiles` | `{ kind = "Set", actor: ActorView, sourceId: string, profile: ControlProfile }` or `{ kind = "Remove", actor: ActorView, sourceId: string }` |
| `contexts` | `{ contextId: string, enabled: boolean }` |
| `selection` | One `{ kind = "Set", actor: ActorView? }`; nil Actor clears selection |

`definition` uses [InputRuntime source declarations](../input/api). `profile` uses [ControlProfile](../actions/client-api#profiles-and-actor-selection). Set replaces the whole source; nil is not removal shorthand. Omitted fields and empty arrays preserve that section.

Only one operation is permitted per input source ID, ActorView/profile-source pair, or context ID. A Set followed by Remove of the same key is a duplicate, not a sequence. Unknown fields, unknown tags and sparse arrays fail validation.

Source IDs must be nonempty strings. Each operation must be a plain table: Remove excludes the definition/profile field, and Set requires it. Input sources and profile sources have separate ownership namespaces; profile sources are also scoped to their exact ActorView.

Dependencies resolve against the complete final graph, so a batch may introduce or remove an input and its routes together. Context enablement also targets that final graph. All Actor arguments must be current available registry identities.

## Guarantees

Validation failure leaves the proposed configuration uninstalled. Success installs inputs, profiles, context enablement and selection before the corresponding public notifications. Equivalent changes and selection of the same Actor preserve continuity. A real Actor switch retires old press ownership and recognition history; held inputs must return to neutral before a fresh press. Changed routes follow the original Action's captured invalidation policy.

Native installation failure can retire physical ownership even when declarations are restored; a failed restoration or mandatory publication faults the owner. Pending focus/device safety work is independent of the proposed declarations and can still retire ownership. Native properties remain separate Roblox writes, so direct native observers do not receive a transaction guarantee.

The same final owner budgets apply as for individual calls: 128 input sources, 64 contexts, 1,024 inputs, 4,096 bindings and 4,096 overrides; 128 profiled Actors, 32 profile sources per Actor and 256 routes per profile. A batch accepts at most 256 input-source operations, 8,192 profile-source operations and 128 context operations. Oversized operation arrays return `InvalidControlChangeSet`.

## Failures

| Reason | Cause |
| --- | --- |
| `ClientNotReady` | Client lifetime is not installed or has shut down |
| `DispatchInProgress` | Input dispatch, validation or another protected transition prevents a coordinated batch |
| `InvalidControlChangeSet` | Invalid shape, field, tag, array or required value |
| `DuplicateInputSourceChange` | Repeated input source |
| `DuplicateProfileSourceChange` | Repeated ActorView/profile-source pair |
| `DuplicateContextChange` | Repeated context |
| `ActorViewUnavailable` | Profile or selection references an unavailable ActorView |
| `InvalidSourceId`, `InvalidProfileSourceId` | Invalid input/profile source key |
| `UnknownContext` | Context does not exist in the final graph |
| `ProfileDependencyMissing` | A remaining route loses an input, context, gesture, sequence or recognizer |
| `NativeCommitFailed` | Native change failed; declarations were restored with required safety retirement |
| `InputRuntimeFaulted` | Restoration or mandatory publication failed |

Input declarations and profiles retain their owning systems' validation/conflict/limit reasons. Actor switching can additionally fail with `StaleActorSwitch`, `ActorSwitchGuardFailed`, `ActorSwitchGuardYielded` or `ActorSwitchCommitFailed`.
