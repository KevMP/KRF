---
title: Recognition API
sidebar_label: Recognition API
---

# Recognition API

Declare these fields in an [InputRuntime source](./api). Durations are finite numbers greater than zero and at most 60 seconds. IDs are nonempty strings. Unknown fields, sparse arrays and unresolved dependencies are rejected.

## Gestures

`gestures` maps Bool input IDs to any of the following entries:

| Kind | Definition |
| --- | --- |
| `Tap` | `{ maxDurationSeconds: number, suppressIfHoldRecognized: boolean? }`; suppression defaults false |
| `Held` | `{ afterSeconds: number }` |
| `LongHeld` | `{ afterSeconds: number }`; must be later than Held if both exist |
| `DoubleTapped` | `{ maxTapDurationSeconds: number, maxGapSeconds: number, arbitration: string? }`; qualifies the first tap, then recognizes on the second press |

`maxGapSeconds` measures from the first release to the second press. The second press may remain held; recognition does not wait for its release. Tap duration and gap boundaries are inclusive. Held and LongHeld each recognize once per press when their threshold is reached, including when a delayed scheduler observes it later.

Double-tap arbitration is `"PreferSpecific"` (default), `"Independent"` or `"DeferredTap"`. DeferredTap requires a Tap in the same source with the same duration bound and no hold suppression. `suppressIfHoldRecognized` requires Held or LongHeld in that source and only suppresses Tap after one of those holds has recognized. Each input/kind pair has one owner, even across sources.

```lua
Input.GetGestures(inputId: string) -> {[string]: {sourceId: string, definition: any}}?
```

### OnGesture

`OnGesture: Event<GestureEvent>` supplies string `inputId` and `contextId`, a `gesture` kind, and numeric `timestamp`, `ordinal` and `triggerInputOrdinal`. The timing fields below are numbers in seconds.

| `gesture` | Additional fields |
| --- | --- |
| `"Tap"` | `pressDurationSeconds`, `recognizedAt` |
| `"Held"`, `"LongHeld"` | `thresholdSeconds`, `elapsedSeconds` |
| `"DoubleTapped"` | `gapSeconds` |

Timestamps use the local monotonic clock. `timestamp` is when KRF emits the event; a deferred Tap's `recognizedAt` retains the earlier qualifying release time. `ordinal` increases within the gesture event stream, and `triggerInputOrdinal` identifies the relevant `OnInput` occurrence. These counters are separate from network request IDs.

## Sequences

| `SequenceDefinition` field | Contract |
| --- | --- |
| `steps` | Nonempty dense array, at most 32 steps |
| `maxGapSeconds` | Required for an ordinary sequence |
| `maxTotalSeconds` | Required for an ordinary sequence |
| `scope` | Optional array of Bool input IDs whose Pressed tokens should also disrupt an attempt |
| `watchedTokens` | Optional array of explicit input/gesture or custom tokens, at most 32 |
| `exclusiveGroup` | Optional sequence group ID; excludes per-sequence timing, scope and watched-token fields |

A step is an input ID string (shorthand for Pressed), `{ inputId, kind = "Pressed" | "Tap" | "Held" | "LongHeld" | "DoubleTapped" }`, or `{ recognizerId, kind = "Custom" }`. `watchedTokens` uses explicit records, not string shorthand. Referenced gestures and recognizers must exist.

Step tokens and explicit watched tokens are always watched. A watched occurrence must advance the current attempt or it ends that attempt; an unwatched occurrence leaves it alone. Scope adds Pressed tokens, except that the press needed to begin a gesture step does not interrupt it. Cancellation of a dependency clears affected progress. Gap and total time bounds are inclusive and apply to token processing times.

`sequenceGroups` maps IDs to:

```lua
{
	policy = "DeferredPrefix",
	maxGapSeconds = number,
	maxTotalSeconds = number,
	scope = { string },
	watchedTokens = { WatchedToken }?,
}
```

Members share the group's token vocabulary and bounds. A group belongs to the same source as its members and requires at least two sequences: every member must extend the shortest member's prefix, with at least one proper extension. Invalid group compositions are rejected rather than selecting a winner by ID.

```lua
Input.GetSequence(sequenceId: string) -> SequenceSnapshot?
-- { sequenceId, sourceId, definition }
```

`OnSequenceMatched: Event<SequenceMatchEvent>` carries `sequenceId: string`, `sourceId: string`, `recognizedAt: number`, `timestamp: number`, `ordinal: number`, `matchedStepCount: number` and `triggerTokenOrdinal: number`. `recognizedAt` is when the completed sequence was first recognized; `timestamp` is when its result is emitted. They can differ for a deferred prefix. Trigger tokens use the recognition pipeline's token counter, not the `OnInput` counter.

## Custom recognizers

| `RecognizerDefinition` field | Contract |
| --- | --- |
| `inputs` | Nonempty array of at most 64 existing input IDs |
| `gestures` | Optional map from one of those input IDs to a nonempty array of declared gesture kinds |
| `maxWindowSeconds` | Maximum recognition window |
| `onEvent(ctx, event)` | Required synchronous callback; returns `CustomMatch?` |
| `onDeadline(ctx)` | Optional synchronous callback for a scheduled deadline; returns `CustomMatch?` |

`event` is a semantic input event, or a gesture event with `kind = "Gesture"`. Returning `{}` reports a match without metadata. Otherwise return `{ metadata = { [string]: string | number | boolean } }`; nil means no match. Numbers must be finite. Metadata is copied and bounded to 32 slots / 4,096 bytes, with nonempty keys of at most 64 bytes. KRF emits at most one custom match per recognizer for one input occurrence. A result returned during Cancelled is ignored.

The first watched event opens the maximum window. Later events and deadline changes do not extend it. At expiry, scalar state and pending deadlines are cleared; the next watched event can open a fresh window. Returning a match does not reset that state or window. `onDeadline` runs only for an explicitly scheduled deadline, not automatically because the maximum window expires.

### RecognizerContext

| Signature | Behavior |
| --- | --- |
| `ctx:GetState(key: string) -> RecognitionScalar?` | Reads framework-owned scalar storage |
| `ctx:SetState(key: string, value: RecognitionScalar?) -> (boolean, string?)` | Writes a string, finite number or boolean; nil removes the key |
| `ctx:Now() -> number` | Current local monotonic time |
| `ctx:ScheduleAfter(seconds: number) -> (boolean, string?)` | Schedules/replaces the recognizer's deadline within its allowed window |
| `ctx:ClearDeadline() -> ()` | Removes its scheduled deadline |

State is bounded to 32 slots, nonempty keys of at most 64 bytes and 4,096 aggregate bytes. The context is valid only inside its callback; using a retained context throws `InactiveRecognizerContext`. Callbacks must not yield.

Invalid `SetState` or `ScheduleAfter` calls return false with `InvalidRecognizerState`, `RecognizerStateLimitExceeded`, `InvalidRecognizerDeadline` or `RecognizerWindowExceeded`, and mark that invocation faulty even if the callback ignores the result. An invalid GetState key returns nil and also marks the invocation faulty. Scheduling during cancellation returns `RecognizerCancelled` without faulting. Callback errors, yields and invalid match results also fault the recognizer.

A fault clears its state, stops further matches and blocks sequences that depend on it. An equivalent source update or a recognition-history reset does not clear the fault. Remove and readd the declaration, or install a different declaration, to create a fresh recognizer. Source changes still need to satisfy installed route dependencies.

```lua
Input.GetRecognizer(recognizerId: string) -> RecognizerSnapshot?
-- { recognizerId, sourceId, definition, faulted, faultReason? }
```

`OnRecognizerMatched: Event<CustomRecognitionEvent>` carries `recognizerId: string`, `sourceId: string`, `timestamp: number`, `ordinal: number`, optional `triggerTokenOrdinal: number` and optional copied `metadata`. Deadline matches have no triggering token. Sequence and custom match events share an increasing result ordinal; gesture and input events have their own counters.

## Failures

| Reasons | Cause |
| --- | --- |
| `InvalidGesture`, `InvalidGesturePolicy` | Invalid fields, duration or arbitration |
| `UnknownGestureInput`, `GestureRequiresBool` | Missing or non-Bool gesture input |
| `DuplicateGestureOwner` | Multiple definitions own the same input/kind |
| `GestureHoldDependencyMissing`, `InvalidHoldThresholdOrder`, `InvalidDeferredTapPair` | Incompatible gesture combination |
| `InvalidSequence`, `InvalidSequenceGroup` | Invalid sequence/group shape or composition |
| `UnknownSequenceInput`, `SequenceRequiresBool`, `UnknownSequenceGesture`, `UnknownSequenceRecognizer` | Invalid step dependency |
| `DuplicateSequenceOwner`, `DuplicateRecognizerOwner` | More than one source declares the same recognition ID |
| `InvalidRecognizer`, `UnknownRecognizerInput`, `UnknownRecognizerGesture` | Invalid custom definition or dependency |
| `InputGestureLimitExceeded` | More than 4,096 gesture definitions |
| `InputSequenceLimitExceeded`, `InputSequenceStepLimitExceeded` | More than 256 sequences or 32 steps per sequence |
| `InputSequenceGroupLimitExceeded` | More than 64 groups |
| `InputRecognizerLimitExceeded`, `InputRecognizerInputLimitExceeded` | More than 128 recognizers or 64 input dependencies per recognizer |

These are declaration failures. A valid recognizer can still fault during execution. [Recognition lifecycle](./recognition) explains history invalidation; [routing](../actions/routes) explains which matches can own a WhileDown Action.
