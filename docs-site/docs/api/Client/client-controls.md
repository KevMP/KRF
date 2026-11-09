---
sidebar_position: 2
---

# ClientControls

`ClientControls` is the frozen client facade for one synchronous coordinated control change.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Controls = require(ReplicatedStorage.Packages.KRF.client.Controls.ClientControls)
```

Public contract types are in `KRF.client.Controls.types`. The facade is installed by ordinary client initialization; no additional config option or public lifecycle handle is required.

## Members

| Kind | Signature |
| --- | --- |
| Method | [`Apply(changeSet: ControlChangeSet) -> (boolean, string?)`](#apply) |

## Methods

### `Apply(changeSet: ControlChangeSet) -> (boolean, string?)` {#apply}

Validates all requested changes against one final graph and publishes them through the existing input and Action owners. Returns `true, nil` for successful local publication, including an empty or equivalent change.

| Field | Supplied records |
| --- | --- |
| `inputs` | Optional array of `{ kind = "Set", sourceId, definition }` or `{ kind = "Remove", sourceId }`; definitions use ordinary InputRuntime source types |
| `profiles` | Optional array of `{ kind = "Set", actor, sourceId, profile }` or `{ kind = "Remove", actor, sourceId }`; profiles use ordinary ClientActionRuntime types |
| `contexts` | Optional array of `{ contextId, enabled: boolean }`, applied to the final context graph |
| `selection` | Optional `{ kind = "Set", actor: ActorView? }`; omit `actor` to clear selection |

Omitted fields and empty arrays leave that registry unchanged. Each operation replaces or removes a whole source; nil definitions are not removal shorthand. Unknown fields, sparse arrays, and unknown kinds are rejected.

One operation is allowed per input `sourceId`, per ActorView/`sourceId` profile pair, and per `contextId`. Even Set followed by Remove is a duplicate, not an imperative sequence.

Final owner budgets remain in force: 128 input sources, 64 contexts, 1,024 inputs, and 4,096 bindings; 128 profiled Actors, 32 profile sources per Actor, and 256 routes per source. Batches are finite and additionally bounded by their owner operation budgets.

| Failure | Meaning |
| --- | --- |
| `ClientNotReady` | The client owner lifetime is not installed or is shut down |
| `DispatchInProgress` | An internal control transition or dispatch prevents public mutation |
| `InvalidControlChangeSet` | Invalid batch shape, field, tag, array, or required operation value |
| `DuplicateInputSourceChange` | Repeated input source key |
| `DuplicateProfileSourceChange` | Repeated ActorView/profile-source pair |
| `DuplicateContextChange` | Repeated context key |
| `ActorViewUnavailable` | Selection or profile Actor is not a current available registry identity |
| `UnknownContext` | An enabled-context operation references no final context |
| `ProfileDependencyMissing` | Some remaining profile references a missing input, context, gesture, sequence, or recognizer |
| `NativeCommitFailed` | Native application failed; previous declarations were restored, with required input safety retirement/rearm |
| `InputRuntimeFaulted` | Input restoration or mandatory publication failed; affected owners fail closed |

Source, binding, recognition, profile, priority/conflict, and resource-limit failures retain their owning systems' reasons. Actor switching can also return `StaleActorSwitch`, `ActorSwitchGuardFailed`, `ActorSwitchGuardYielded`, or `ActorSwitchCommitFailed`.

A validation failure causes no installed mutation. A native commit failure may retire physical ownership even when declarations are restored. Success is local and does not guarantee server acceptance or cancellation.

## Related

- [Coordinated client controls](/Action/client-controls)
- [Action input](/Action/action-input)
- [ClientActionRuntime](../Action/client-action-runtime)
- [Client initialization](/api/Client/)
