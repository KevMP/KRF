---
title: Action routes
sidebar_label: Input routes
---

# Action routes

An input named `AbilitySlot1` describes what the player operated. A route chooses which Action that means for an Actor. Keeping those separate lets equipment change an ability without taking ownership of its key bindings.

`InputRuntime` recognizes the input. `ClientActionRuntime` selects a route, prepares a request and tracks any release or toggle ownership. The server still owns execution.

## Map an input to an Action

Assume `Dash` is an installed Bool input in an enabled context, and `Movement.Dash` is registered, granted and present in the shared request catalog:

```lua
local Actions = KRF.ClientActionRuntime
assert(Actions.SetProfileSource(actorView, "Movement", {
	routes = {
		{
			when = { kind = "Input", inputId = "Dash", gesture = "Pressed" },
			target = { kind = "Fixed", actionId = "Movement.Dash" },
		},
	},
}))
assert(Actions.SetControlledActor(actorView))
```

A profile belongs to one source on one exact ActorView. Only the controlled Actor's profile dispatches automatically. Selecting an Actor locally does not authorize control on the server.

Profiles can also route gesture, sequence and custom recognizer matches. Each route key uses the highest-priority source whose `requiredContexts` are all enabled. Disabling those contexts lets a lower-priority eligible source take over. Equal source priorities for the same key are rejected, even when a context currently disables one of them.

An input's own context still controls whether it produces input. `requiredContexts` adds route-specific conditions, such as routing an ability differently while a menu is open. Queries inspect whether a route is mapped, gated or absent without running a Dynamic resolver.

## Choose an activation policy for the concrete Action

Policies are a client startup catalog keyed by Action ID, not input ID:

```lua
local policies: KRF.ActionInputPolicies = {
	Meditate = { activation = "WhileDown" },
	Aura = { activation = "Toggle" },
}
```

OneShot is the default: each selected trigger requests Start and gives up its local Stop/Interrupt authority after admission. WhileDown requests Stop on release of its owning press. Toggle ignores release and requests Stop on the next matching trigger. WhileDown and Toggle require a Stop contract. Use a [direct request](./requests) if game code needs to keep a OneShot Start's ID for manual follow-ups.

Stop delivers intent to `onStopRequested`; it does not end an Action by itself. Different client lifecycles need different concrete Action IDs. A payload field cannot switch the policy attached to one ID.

## Resolve equipment at the moment of input

A Dynamic target can ask a game-owned equipment module which Action is equipped:

```lua
target = {
	kind = "Dynamic",
	resolve = function(ctx)
		return { actionId = getEquippedActionId(ctx.actor) }
	end,
}
```

The resolver must not yield. Returning nil declines that selection. It may also return `parameters`, which become the entire Start payload unless the chosen Action has a `startParameters` producer.

If the player starts charging one Action and changes equipment before release, release still belongs to the original concrete Action. KRF does not run the resolver again to guess what should stop. Replacing the route itself is an invalidation and follows the original Action's invalidation policy.

## Sample parameters where they belong

`startParameters(ctx)` and `stopParameters(ctx)` return complete payloads matching the shared contract. KRF never implicitly merges them with resolver parameters. Producers are synchronous, and their callback references are captured at initialization.

The Stop producer runs for genuine release or matching Toggle-off. Focus loss, context disablement, a rebind, route loss or an Actor switch is cancellation, so those paths do not sample a fictional release payload.

If automatic Stop preparation fails before admission, KRF can send a permitted Interrupt against the original Start. Once Stop has been admitted, an Unknown outcome does not cause replay or a fallback Interrupt. A temporarily full request queue retains a bounded prepared follow-up rather than rerunning the producer.

## Decide what cancellation means

WhileDown defaults to `onInvalidation = "Interrupt"`; other policies default to `"Keep"`. Interrupt requires wire permission. Keep drops automatic ownership and leaves server lifetime to the Action. Reinstalling the same route later does not reattach a retired activation.

WhileDown needs a verified live Bool press. Pressed, live holds, double taps and compatible immediate final-step matches can provide one. Tap, deferred sequence results and deadline matches cannot. In an immediate sequence, the final key owns release; releasing an earlier key does not stop the Action.

Toggle-off must match the same ActorView, effective route continuity and concrete Action. Switching to another equipped Action does not accidentally stop the old one. Once Stop is locally admitted, the toggle match is retired even if the server has not ended the Action yet.

## Resolve overlapping matches deliberately

When a final key also completes a sequence, the sequence's default Exclusive dispatch lets its winning immediate match consume that occurrence's ordinary input route. Custom routes default to Independent; opt one into Exclusive when it should compete. Among exclusive sequence/custom matches, dispatch priority wins first, then sequences over custom matches, then longer sequences. An unresolved tie is ambiguous and dispatches neither tied winner; KRF does not choose by an arbitrary ID.

Independent sequence or custom routes can dispatch alongside other matches. Use this intentionally, since one input occurrence can then request several Actions. The ordinary input route remains the fallback for its root occurrence and can still be consumed by an immediate Exclusive match. Selection happens before request preparation: a failed resolver or rejected request does not fall through to a lower-ranked route.

Use [ClientControls](../controls/guide) when installing inputs and profiles together. The [client Action API](./client-api) gives all profile fields, policy defaults and request events.
