---
title: InputRuntime API
sidebar_label: API
---

# InputRuntime API

`KRF.InputRuntime` is a frozen client facade installed by `KRF.Client.Init`. Calls use dot syntax. Input declaration and snapshot shapes below are structural types; they are not all exported as `KRF` type aliases.

## Source declarations

```lua
Input.SetSource(sourceId: string, definition: InputSourceDefinition) -> (boolean, string?)
Input.RemoveSource(sourceId: string) -> (boolean, string?)
Input.SetContextEnabled(contextId: string, enabled: boolean) -> (boolean, string?)
```

`sourceId` is a nonempty owner key. Set replaces the complete source; Remove succeeds for an absent source. Outside input delivery, successful mutations return `true, nil` after installation. Invalid declarations or dependencies return `false, reason` without installing the proposed configuration. Native commit failures have the separate recovery behavior described under [Failures](#failures).

During ordinary input delivery, these mutations can enter a bounded deferred queue. True then means queued, and queries inside that callback can still see the old configuration. Dependencies are checked when the queued mutation runs; a later failure is reported diagnostically. Mutations during a protected coordinated transition instead return `DispatchInProgress`.

| `InputSourceDefinition` field | Shape / default |
| --- | --- |
| `priority` | Optional finite number, default `0`; selects binding overrides |
| `contexts` | Optional map of context ID to `{ priority: number, sink: boolean }` |
| `inputs` | Optional map of input ID to `InputDefinition` |
| `bindingOverrides` | Optional map of input ID to binding-slot map |
| `gestures` | Optional input ID to gesture definitions; [recognition API](./recognition-api) |
| `sequences` | Optional sequence ID to sequence definition |
| `sequenceGroups` | Optional group ID to deferred-prefix group definition |
| `recognizers` | Optional recognizer ID to custom recognizer definition |

Context priority must be an integer in the signed 32-bit range. Context and input IDs each have a single declaring owner. Newly owned contexts are disabled. Definitions must be plain tables with recognized fields.

| `InputDefinition` field | Contract |
| --- | --- |
| `context` | Existing context ID in the final configuration |
| `type` | `Enum.InputActionType.Bool`, `Direction1D`, `Direction2D`, `Direction3D` or `ViewportPosition` |
| `displayName` | Optional string |
| `bindings` | Map of nonempty slot ID to `BindingDefinition` |

Each override replaces one declared slot. Highest source priority wins; tied highest overrides fail with `BindingOverrideConflict`. Source priority does not allow duplicate input or context owners.

### BindingDefinition

Every field is optional, but a binding must contain a valid native input source. Fields must suit the input type.

| Fields | Type / restriction |
| --- | --- |
| `keyCode` | `Enum.KeyCode`; Bool and 1D exclude vector/pointer keys; 2D accepts `Thumbstick1`, `Thumbstick2` or `MouseDelta`; 3D uses directional fields instead |
| `up`, `down` | `Enum.KeyCode`; directional inputs |
| `left`, `right` | `Enum.KeyCode`; 2D or 3D |
| `forward`, `backward` | `Enum.KeyCode`; 3D only |
| `primaryModifier`, `secondaryModifier` | `Enum.KeyCode` |
| `pressedThreshold`, `releasedThreshold` | Bool only; each in `[0, 1]`; effective pressed threshold must be at least released threshold, using native defaults `0.5` and `0.2` for omitted fields |
| `scale` | Finite number; directional inputs |
| `vector2Scale`, `vector3Scale` | Finite `Vector2` / `Vector3`, matching 2D / 3D input |
| `responseCurve` | Number in `[1, 10]`; 2D thumbsticks only |
| `clampMagnitudeToOne` | Boolean; directional inputs |
| `pointerIndex` | Integer in `[0, 2147483647]`; viewport only |
| `uiButton` | `GuiButton`; Bool only |
| `uiModifier` | `GuiButton` |
| `displayName`, `displayImage` | String / `Content` |

Viewport bindings require `keyCode = Enum.KeyCode.MousePosition` or the Touch key. Numeric binding fields must be finite and fit the native 32-bit float range. Omitted native settings use Roblox's defaults.

## Queries

| Signature | Return value |
| --- | --- |
| `GetInput(inputId: string) -> InputSnapshot?` | `{ id, sourceId, contextId, inputType, displayName? }` |
| `GetContext(contextId: string) -> ContextSnapshot?` | `{ id, sourceId, priority, sink, enabled }` |
| `GetEffectiveBindings(inputId: string) -> {[string]: BindingSnapshot}?` | Slot map; each value is `{ sourceId, definition }`, including override ownership |
| `GetGestures(inputId: string) -> {[string]: GestureSnapshot}?` | Gesture kind map; each value is `{ sourceId, definition }` |
| `GetSequence(sequenceId: string) -> SequenceSnapshot?` | `{ sequenceId, sourceId, definition }` |
| `GetRecognizer(recognizerId: string) -> RecognizerSnapshot?` | `{ recognizerId, sourceId, definition, faulted, faultReason? }` |

Snapshots are read-only. Queries return nil for missing entries or before client readiness. `GetGestures` returns an empty map for a known input with no gestures. These queries report configuration and recognizer status; there is no current-value polling method.

## Native labels

```lua
Input.BindActionLabel(inputId: string, label: InputActionLabel) -> (boolean, string?)
Input.UnbindActionLabel(label: InputActionLabel) -> (boolean, string?)
```

Bind associates the label with the input's current native `InputAction` and follows replacements. Rebinding a label replaces its association. Input removal and label destruction end the association. If game code replaces the label's `InputAction`, KRF releases its association on the next reconciliation instead of overwriting that value. Unbind succeeds even when no association exists and only clears a native value KRF still owns.

Failures include `UnknownInput`, `InvalidInputActionLabel` and readiness/fault failures.

## Events

`OnInput: Event<SemanticInputEvent>` carries these common fields:

| Field | Type / meaning |
| --- | --- |
| `inputId`, `contextId` | Semantic IDs |
| `inputType` | `Enum.InputActionType` |
| `timestamp` | Local monotonic occurrence time |
| `ordinal` | Increasing local input occurrence order |

| `kind` | Additional fields |
| --- | --- |
| `"Pressed"`, `"Released"` | `value: boolean` |
| `"StateChanged"` | `value: number \| Vector2 \| Vector3` |
| `"Cancelled"` | `reason: string` |

Bool event values are booleans. Direction1D values are numbers, Direction2D and ViewportPosition values are Vector2, and Direction3D values are Vector3. Cancelled is emitted for an active Bool or directional input; viewport input has no active press to cancel. Cancellation does not fabricate a Released or neutral StateChanged event, so clear cached held/axis state when your input is cancelled.

`OnGesture`, `OnSequenceMatched` and `OnRecognizerMatched` are specified in the [recognition API](./recognition-api). All use the shared read-only [Event interface](../getting-started/events).

## Failures

| Reason | Cause |
| --- | --- |
| `ClientNotReady` | No active client owner |
| `DispatchInProgress` | Mutation attempted during a protected coordinated transition |
| `InputMutationQueueLimitExceeded` | Deferred mutation queue is full |
| `InvalidSourceId`, `InvalidDefinition` | Invalid source key, shape or field |
| `InvalidContext`, `InvalidInput`, `InvalidBinding` | Invalid declaration or incompatible native binding |
| `InvalidContextEnabled`, `UnknownContext` | Invalid enablement value or missing context |
| `DuplicateContextOwner`, `DuplicateInputOwner` | Multiple declaring sources use the same ID |
| `UnknownInput`, `UnknownBindingSlot` | Override references a missing declaration |
| `BindingOverrideConflict` | Equal highest override priorities for one slot |
| `ProfileDependencyMissing` | The proposed input configuration would invalidate an installed Action profile |
| `NativeCommitFailed` | Native installation failed; declarations were restored, but unsafe physical ownership may have been retired |
| `InputRuntimeFaulted` | Restoration or required publication failed; runtime fails closed |

Recognition failures retain their [specific reasons](./recognition-api#failures). Configuration limits are 128 sources, 64 contexts, 1,024 inputs, 4,096 declared bindings and 4,096 overrides. Exceeding them returns the corresponding `InputSourceLimitExceeded`, `InputContextLimitExceeded`, `InputLimitExceeded`, `InputBindingLimitExceeded` or `InputOverrideLimitExceeded` reason.

Use [ClientControls.Apply](../controls/api) for changes that need coordinated input, profile, enablement and Actor selection updates.
