---
title: Knock out cultivators
sidebar_label: 5. Knock out cultivators
sidebar_position: 6
description: Knock out a cultivator whose Vitality reaches zero, stop everything they're doing, and revive them.
---

# Knock out cultivators

Vitality can reach zero, but nothing happens when it does. In this chapter a cultivator at zero is knocked out: for five seconds they can't move or act, anything they were doing stops, and then they recover with full Vitality.

## The KnockedOut Tag

```bash
npm run createTag -- --name KnockedOut --duration 5 --property WalkSpeed:set=0 --visibility ClientVisible
```

The Tag roots the cultivator through the Movement Controller, and its five-second duration is the length of the knockout.

A knocked-out cultivator shouldn't be able to start anything. Add the Tag to `blockedTags` in `src/server/Actions/Meditate.luau`:

```lua
blockedTags = { "Meditating", "KnockedOut" },
```

and in `src/server/Actions/QiBolt.luau`:

```lua
blockedTags = { "KnockedOut" },
```

`blockedTags` is only checked when an Action starts. A cultivator who is already meditating when they're knocked out would keep meditating, so something has to stop running Actions as well.

## A Knockouts Controller

The knockout depends on one Actor's Vitality, Tags and Actions, so it's another Controller:

```bash
npm run createController -- --name Knockouts --depends-on ResourceController --depends-on TagController --depends-on ActionController
```

```lua title="src/server/Controllers/Knockouts.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Knockouts: KRF.ControllerDefinition = {
	key = "Knockouts",
	factory = function(actor: KRF.Actor): KRF.Controller
		local resources = actor:GetController("ResourceController") :: KRF.ResourceController
		local tags = actor:GetController("TagController") :: KRF.TagController
		local actions = actor:GetController("ActionController") :: KRF.ActionController
		local running: { [number]: boolean } = {}

		local function knockOut(): ()
			tags:AddTag("KnockedOut")

			for sequenceId: number in table.clone(running) do
				actions:InterruptAction(sequenceId, "KnockedOut")
			end
		end

		local connections: { KRF.Connection } = {
			actions.OnActionStarted:Connect(function(event: KRF.ActionLifecycleEvent)
				running[event.sequenceId] = true
			end),
			actions.OnActionEnded:Connect(function(event: KRF.ActionLifecycleEvent)
				running[event.sequenceId] = nil
			end),
			actions.OnActionInterrupted:Connect(function(event: KRF.ActionInterruptedEvent)
				running[event.sequenceId] = nil
			end),
			resources.OnResourceChanged:Connect(function(change: KRF.ResourceChange)
				local emptied: boolean = change.resourceId == "Vitality"
					and change.currentNewValue <= change.minNewValue

				if emptied and not tags:HasTag("KnockedOut") then
					knockOut()
				end
			end),
			tags.OnTagExpired:Connect(function(_actor: KRF.Actor, tagId: string)
				if tagId == "KnockedOut" then
					resources:SetCurrent("Vitality", resources:GetMax("Vitality") or 0)
				end
			end),
		}

		return {
			Destroy = function(): ()
				for _, connection: KRF.Connection in connections do
					connection:Disconnect()
				end
			end,
		}
	end,
	dependsOn = {
		"ResourceController",
		"TagController",
		"ActionController",
	},
}

return Knockouts
```

The Controller watches Vitality through `OnResourceChanged`. When it reaches the minimum, the Controller applies KnockedOut and interrupts everything the Actor is running. KRF doesn't hand out a list of running Actions, so the Controller keeps its own from the Action Controller's start, end and interrupt events. It loops over a copy because each interruption fires an event that removes an entry from the original.

Recovery waits for `OnTagExpired`, which fires when the five seconds run out, and restores Vitality to its maximum.

## Show the knockout

Players should know why they can't move. In the HUD's `status` function, check the Tag before the meditation line:

```lua
if view:GetTags():HasTag("KnockedOut") then
	text ..= " · Knocked out"
elseif view:GetActions():IsActionActive("Meditate") then
	text ..= " · Meditating"
end
```

## Checkpoint

Start a two-player test. Meditate until your Qi is full, then keep hitting the other player with bolts while they meditate. Vitality regenerates between bolts, so it takes about seven. On the hit that empties it, their meditation ends, their HUD shows `Knocked out`, and F and Q do nothing. Five seconds later they can move again with full Vitality.

## Next

[Break through](./break-through) gives cultivators a reason to gather a full bar of Qi.
