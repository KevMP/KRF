---
title: Input recognition
sidebar_label: Recognition guide
---

# Input recognition

Use a gesture when the timing of one input matters, such as tapping Guard or holding it down. Use a sequence when the order of several inputs matters. `InputRuntime` recognizes both, so every consumer can work from the same interpretation of the player's input.

Recognition definitions live in ordinary input sources. Their events are useful for local feedback; [Action routes](../actions/routes) can also consume matches to request server Actions.

## Start with a gesture

For an existing Bool input named `Guard`, this source adds tap and hold recognition:

```lua
assert(KRF.InputRuntime.SetSource("GuardGestures", {
	gestures = {
		Guard = {
			Tap = { maxDurationSeconds = 0.2 },
			Held = { afterSeconds = 0.4 },
		},
	},
}))
```

Tap recognizes a release within its duration bound. Held recognizes once the press reaches its threshold; LongHeld provides a second, later threshold. Each hold fires once per press. If you declare both holds, a long press can produce both events.

DoubleTapped recognizes when a qualifying first tap is followed by a second press within the gap bound. It fires on that second press, so the player can keep the second press held. Arbitration decides how Tap routes compete with that interpretation: `PreferSpecific` favors DoubleTapped without retracting anything already started by the first tap, while `Independent` keeps Tap eligible too. `DeferredTap` holds the first Tap until the second-press window expires; a matching second press consumes it instead.

Set `suppressIfHoldRecognized` on Tap when a hold declared in that same source should rule it out. Gesture events describe what was recognized; arbitration can make a Tap ineligible for routing without removing its public event. The [API](./recognition-api) gives the valid combinations and timing fields.

## Recognize an ordered combination

Assuming Bool inputs `FirstSign`, `SecondSign` and `FinalSign` already exist:

```lua
assert(KRF.InputRuntime.SetSource("Signs", {
	sequences = {
		Seal = {
			steps = { "FirstSign", "SecondSign", "FinalSign" },
			maxGapSeconds = 0.5,
			maxTotalSeconds = 1.2,
		},
	},
}))
```

A string step means that input's `Pressed` token. Explicit steps can use a gesture or a custom recognizer match. Both time bounds are required for an ordinary sequence: one bounds each gap, the other the entire attempt.

KRF watches the sequence's step tokens. A watched token that doesn't advance an attempt ends that attempt; unrelated tokens are ignored. Add input IDs to `scope` when their presses should also break a combination, or use `watchedTokens` for additional gesture or custom matches. Pressing the input needed to begin a gesture step does not itself break that step.

Ordinary sequences match immediately. If a short sequence is a prefix of a longer one and only one should win, put both in a `DeferredPrefix` group. The group owns their shared time bounds, scope and watched tokens. KRF holds the shorter result while a longer continuation is possible, then resolves the pending match when that decision can be made.

A result released from a deferred-prefix group cannot own a WhileDown Action, even if the player still happens to hold a key. Use [OneShot or Toggle policies](../actions/routes) for those results. An ordinary immediate sequence can use its verified final press for WhileDown.

## Add a custom recognizer only for a custom rule

A recognizer subscribes to a declared set of inputs and optional gestures. Its synchronous `onEvent` returns nil while collecting input, or a small match record when its rule succeeds. `onDeadline` can resolve a pending decision later.

Use the supplied context for scalar state and deadlines. The first watched event opens a window bounded by `maxWindowSeconds`; later events and rescheduled deadlines cannot extend it. Once that window expires, KRF clears its state. Returning a match does not clear state early, so update it explicitly if the next event should begin a new pattern.

`GetRecognizer` reports faults caused by callback errors, yields, invalid state operations or invalid matches. A fault stops that recognizer and blocks sequences that depend on it. Reinstalling an equivalent declaration preserves the fault; removing and readding the declaration creates a fresh recognizer.

Keep gameplay effects in the consumer of a match. A recognizer can then serve local feedback and Action routing without sending the same request twice. Its callbacks are trusted game code, and KRF's bounded context storage does not constrain state captured in your own closures.

## Cancellation clears history

Disabling a required context, replacing relevant declarations, losing input focus or switching the controlled Actor can retire recognition history. An equivalent update preserves continuity where the installed configuration is unchanged. A key held across an invalidation cannot masquerade as a fresh press.

Gesture, sequence and custom match events describe recognized input. They do not prove a route was selected, a request was admitted, or the server started an Action. Observe [Action request events](../actions/client-api#request-observations) for those later decisions.
