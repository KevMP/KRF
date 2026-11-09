---
sidebar_position: 13
---

# Action input

`ClientActionRuntime` maps semantic input routes to concrete Actions. Each Action's static client policy decides whether it fires once, stays bound to a held key, or toggles. The server's `ActionController` decides whether requests execute.

## Declare the Action's policy

Put policies in a client-only catalog supplied through [initialization](../initializing-krf#client-initialization). Keep the shared [request schemas](./action-requests) declarative. This example assumes Rasengan has typed `{ aim }` Start and `{ releaseAim }` Stop schemas, Stop enabled, `allowInputInterrupt = true`, `requiresClientRelease = true`, and `onDisconnect = "Interrupt"`. Fireball accepts typed `{ aim }` Start parameters.

```lua title="ClientActionInputPolicies.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ActionTypes = require(ReplicatedStorage.Packages.KRF.client.Action.types)

local function currentAim(): { x: number, y: number, z: number }
	local camera = assert(workspace.CurrentCamera, "Camera unavailable")
	local direction = camera.CFrame.LookVector
	return { x = direction.X, y = direction.Y, z = direction.Z }
end

local policies: ActionTypes.ActionInputPolicies = {
	["Combat.Rasengan"] = {
		activation = "WhileDown",
		startParameters = function()
			return { aim = currentAim() }
		end,
		stopParameters = function()
			return { releaseAim = currentAim() }
		end,
	},
	["Combat.Fireball"] = {
		activation = "OneShot",
		startParameters = function()
			return { aim = currentAim() }
		end,
	},
	["Mode.Aura"] = { activation = "Toggle" },
}
return policies
```

| Policy field | Contract |
| --- | --- |
| `activation` | `"OneShot"` by default, or `"WhileDown"` / `"Toggle"` |
| `startParameters(ctx)` | Returns the entire Start payload; without it, the resolver's parameters are used |
| `stopParameters(ctx)` | Returns the entire Stop payload on genuine release or matching Toggle-off |
| `onInvalidation` | `"Interrupt"` by default for WhileDown; `"Keep"` by default for Toggle |

Callbacks run synchronously and must not yield. Their frozen context contains `actor`, `actionId`, `routeKey`, optional verified `input` press ownership, and optional `resolvedParameters` for Start. Stop also receives `originalStartRequestId`; resolver payload tables are not retained for release. Payloads are never implicitly merged. KRF snapshots policy entries and callback references at initialization; changing the original catalog later has no effect.

An errored, yielding, or invalid Start producer aborts that selected request. A Stop producer or encoding failure before admission sends a permitted Interrupt against the original Start. Once Stop is admitted, Unknown never causes automatic replay or Interrupt. A temporarily full command queue retains one encoded, not-admitted follow-up per original activation and drains when capacity changes; it does not rerun the producer.

## Route a slot once

After input setup and ActorView acquisition, a game-owned equipment module can supply `getEquippedActionId`. The resolver only chooses the concrete Action:

```lua
local Actions = require(ReplicatedStorage.Packages.KRF.client.Action.ClientActionRuntime)

local ok, reason = Actions.SetProfileSource(actorView, "Equipment", {
	routes = {
		{
			when = { kind = "Input", inputId = "AbilitySlot1", gesture = "Pressed" },
			target = {
				kind = "Dynamic",
				resolve = function()
					return { actionId = getEquippedActionId() }
				end,
			},
		},
	},
})
assert(ok, reason)
assert(Actions.SetControlledActor(actorView))
```

The Input source must declare `AbilitySlot1` as a Bool input and enable its context. Equipping Rasengan starts a charge; releasing that exact press samples release aim. Equipping Fireball makes the next press fire once. Changing equipment behind an unchanged route does not resolve again or retarget a held Rasengan.

Actual route replacement/removal, context loss, rebind, focus loss, Actor switch or ActorView teardown invalidates the original activation. WhileDown defaults to Interrupt without calling the Stop producer. Keep detaches automatic input ownership and leaves the server Action running. Reinstalling a route does not reattach it. Native cancellation or disabling a context never manufactures genuine release.

## Final-key sequences and Toggle

The same policy applies to compatible semantic triggers. With live Bool inputs `X`, `Q`, and `Z` in an enabled context, install an immediate sequence and route it:

```lua
local Input = require(ReplicatedStorage.Packages.KRF.client.Input.InputRuntime)
assert(Input.SetSource("Signs", {
	sequences = {
		Cast = { steps = { "X", "Q", "Z" }, maxGapSeconds = 0.5, maxTotalSeconds = 2 },
	},
}))
assert(Actions.SetProfileSource(actorView, "Signs", {
	routes = {
		{
			when = { kind = "Sequence", sequenceId = "Cast" },
			target = { kind = "Fixed", actionId = "Combat.Rasengan" },
		},
	},
}))
```

Press X, Q, then hold Z. Z owns the charge; releasing X or Q does not stop it. WhileDown also accepts live Pressed, DoubleTapped, Held, LongHeld and compatible immediate custom matches. Tap, deferred matches, timeouts, analog inputs and stale/ambiguous press owners cannot start WhileDown. KRF rechecks the epoch after the producer; refusal does not fall through to a competing route.

Toggle ignores key release. A second trigger must match the same ActorView, effective route continuity and concrete Action. It runs the original Stop producer without another Start producer. Locally admitted Stop retires toggle matching even if the server Action remains alive; the next trigger can request a new Start. Changing the selected Action does not toggle off a different one. Keep invalidation discards matching ownership and the original's client follow-up authority permanently; the server Action continues under its independent lifetime rules.

For a declared `Aura` Bool input, route `Mode.Aura` after enabling its parameterless Stop in the shared schema. Its server Action must also be declared and granted:

```lua
assert(Actions.SetProfileSource(actorView, "Aura", {
	routes = {
		{
			when = { kind = "Input", inputId = "Aura", gesture = "Pressed" },
			target = { kind = "Fixed", actionId = "Mode.Aura" },
		},
	},
}))
```

The first press produces an admitted Start; the matching second press produces `ToggleOff`, then a Stop admission if Stop succeeds locally. Observe both through [OnActionRequest](./action-requests#observe-local-requests).

## Q to Dash

For an existing `Q` Bool input bound to the Q key in an enabled context, map its press to a granted parameterless `Movement.Dash` whose shared request entry is `{}`. The omitted client policy defaults to OneShot:

```lua
assert(Actions.SetProfileSource(actorView, "Movement", {
	routes = {
		{
			when = { kind = "Input", inputId = "Q", gesture = "Pressed" },
			target = { kind = "Fixed", actionId = "Movement.Dash" },
		},
	},
}))
```

The same observation subscription receives Dash's local Start admission and server outcome, or final-Z Rasengan's admission and genuine release. Ordinary OneShot release emits no local input transition. Request observations do not play effects or decide prediction policy.

## Explicit requests and server lifetime

An input-selected OneShot retires its Start's Stop/Interrupt authority after successful local admission, even when the wire schema supports follow-ups. Pending results still correlate to the original request. Use a direct request when game code needs to retain an original id for manual follow-ups.

Direct calls bypass input policies and producers. Supply full parameters and retain the returned original id yourself:

```lua
local original, reason = Actions.RequestAction(actorView, "Combat.Rasengan", { aim = aim })
if original == nil then
	warn(reason)
	return
end
-- Later, using the original id retained by this caller:
local stopped, stopReason = Actions.RequestStop(original, { releaseAim = releaseAim })
if stopped == nil then
	warn(stopReason)
	-- Explicit fallback is the caller's choice; direct Stop never samples a producer.
	Actions.RequestInterrupt(original, "StopPreparationFailed")
end
```

Here `actorView`, `aim` and `releaseAim` are game-supplied values matching the shared schema. Returned ids mean local admission, not server acceptance or a running instance. Stop delivers nonterminal intent to `onStopRequested`; only the server Action decides to End. Early release before Start acknowledgement is supported, and Unknown does not prove denial. Absence of an ActionsView never proves a ServerOnly Action ended.

A successful direct follow-up for an automatic activation retires that input ownership before another release can duplicate it. There is no public activation-id enumeration. A detached Keep Action needs game-authored server lifetime handling. [OnActionRequest](./action-requests#observe-local-requests) reports its original local input decision separately from any server outcome.

For directly started Actions, Accepted Stop leaves follow-up authority usable because Stop is nonterminal. A definitively Accepted Interrupt releases that authority automatically. When game code deliberately gives up further control, call `Actions.RetireRequest(original)`. This is local-only: it preserves pending results and does not end the server Action. Unknown or Rejected Interrupts do not imply termination; late Accepted results during the command grace window still retire the original.

## Validation {#validation}

Policy failures return `system = "ActionInput"` before networking or owner publication:

| Reason | Cause |
| --- | --- |
| `ActionInputPoliciesInvalid` / `ActionInputPolicyInvalid` | Catalog/entry is not a plain table |
| `ActionInputPolicyLimitExceeded` | More than 4,096 entries |
| `ActionInputPolicyUnknownAction` | Policy id is absent from the shared request catalog |
| `ActionInputPolicyFieldUnknown` / `ActionInputProducerInvalid` | Unknown field or non-function callback |
| `ActionInputActivationInvalid` / `ActionInputInvalidationInvalid` | Unsupported policy value |
| `ActionInputReleasePolicyRequired` | A release-required wire contract lacks explicit WhileDown |
| `ActionInputStopRequired` | WhileDown or Toggle lacks a declared Stop |
| `ActionInputStopProducerRequired` | Automatic Stop needs parameters and has no producer |
| `ActionInputInterruptRequired` | Stop producer or Interrupt invalidation lacks wire permission |

Different lifecycles require different concrete Action ids. A payload such as `techniqueId` does not select another policy.

## Related

- [Observe local admissions, input decisions and outcomes](./action-requests#observe-local-requests)
- [Action requests](./action-requests)
- [Action lifecycle](./action-lifecycle)
- [ClientActionRuntime API](/api/Action/client-action-runtime)
