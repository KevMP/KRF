---
title: Fire a Qi bolt
sidebar_label: 4. Fire a Qi bolt
sidebar_position: 5
description: Add an aimed technique that costs Qi, has a cooldown, damages Vitality and slows its target.
---

# Fire a Qi bolt

Cultivators can gather Qi but have nothing to spend it on. In this chapter you add the Qi Bolt: press Q to fire at whoever is under your mouse. It costs 15 Qi, has a two-second cooldown, takes 20 Vitality from its target and slows them briefly.

## Vitality, a cooldown and a stagger

Players need health for the bolt to damage. Use a Resource rather than the Humanoid's `Health`; that gives it regeneration and server ownership, and lets clients read it like Qi. The Humanoid's own health stays untouched, so nobody dies; chapter 5 decides what happens at zero.

```bash
npm run createResource -- --name Vitality --max 100 --regen 2 --visibility ClientVisible
npm run createResource -- --name BoltCooldown --max 1 --regen 0.5 --visibility ClientVisible
npm run createTag -- --name Staggered --duration 1.5 --duplicate-behavior Refresh --property WalkSpeed:multiply=0.5 --visibility ClientVisible
```

The cooldown is a Resource too. The bolt will require it to be full and spend all of it, and it refills in two seconds at a rate of 0.5. Because it's `ClientVisible`, a HUD could draw it later without any extra code.

Staggered halves `WalkSpeed` for 1.5 seconds, and a second hit restarts the timer. The Movement Controller from chapter 3 applies it with no changes.

## The Action

```bash
npm run createAction -- --name QiBolt --requestable --auto-grant --requirement BoltCooldown:minPercent=1 --cost Qi=15 --cost BoltCooldown=1 --lock Stance --start-field X:F32 --start-field Y:F32 --start-field Z:F32
```

This writes the Action and, because of `--requestable`, its entry in `src/shared/ActionRequests` and a policy in `src/client/ActionInputPolicies`. The start fields are the aim direction the client sends with each request. KRF's network schemas have no vector type, so a direction travels as three numbers.

Firing needs a raycast, and the sect techniques in chapter 8 will need the same one, so put it in its own server module, `src/server/Combat.luau`:

```lua title="src/server/Combat.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local KRF = require(ReplicatedStorage.Packages.KRF)

export type Aim = { X: number, Y: number, Z: number }

local Combat = {}

function Combat.Cast(actor: KRF.Actor, aim: Aim, range: number): KRF.Actor?
	local model: Model? = actor.model
	local root: BasePart? = if model ~= nil then model:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
	local direction: Vector3 = Vector3.new(aim.X, aim.Y, aim.Z)

	if model == nil or root == nil or math.abs(direction.Magnitude - 1) > 0.01 then
		return nil
	end

	local params: RaycastParams = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }

	local result: RaycastResult? = Workspace:Raycast(root.Position, direction * range, params)
	local hitModel: Model? = if result ~= nil then result.Instance:FindFirstAncestorOfClass("Model") else nil

	return if hitModel ~= nil then KRF.ActorRegistry.GetActorByModel(hitModel) else nil
end

function Combat.Hit(target: KRF.Actor, damage: number, tagId: string): ()
	local resources = target:GetController("ResourceController") :: KRF.ResourceController
	local tags = target:GetController("TagController") :: KRF.TagController

	resources:Drain("Vitality", damage)
	tags:AddTag(tagId)
end

return Combat
```

`Cast` refuses an aim that isn't a unit vector. The aim comes from the client and only its shape is checked by KRF, so the server has to decide whether the values make sense. `Hit` drains Vitality and applies a Tag through the target's own Controllers.

Now give the Action its behavior in `src/server/Actions/QiBolt.luau`:

```lua title="src/server/Actions/QiBolt.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Combat = require(script.Parent.Parent.Combat)

local RANGE: number = 60
local DAMAGE: number = 20

local function QiBolt(): KRF.ActionDefinition
	return {
		id = "QiBolt",
		visibility = "ClientVisible",
		autoGrant = true,
		resourceRequirements = { BoltCooldown = { minPercent = 1 } },
		costs = {
			Qi = 15,
			BoltCooldown = 1,
		},
		locks = { "Stance" },
		onStart = function(context: KRF.ActionExecutionContext): ()
			local target: KRF.Actor? = Combat.Cast(context.actor, context.parameters, RANGE)

			if target ~= nil then
				Combat.Hit(target, DAMAGE, "Staggered")
			end

			context:End()
		end,
	}
end

return QiBolt
```

The bolt never spends Qi itself. `costs` and `resourceRequirements` are checked before the Action starts and paid in one step when the server accepts it. If the player can't afford it, or the cooldown isn't full, the request is rejected and nothing is spent. `context.parameters` holds the aim, already checked against the schema.

## Stop meditating to fire

Both Actions take a lock named `Stance`, so a cultivator can't fire while meditating. To let the bolt win instead, allow it to interrupt meditation. In `src/server/Actions/Meditate.luau`, add the lock and the permission:

```lua
locks = { "Stance" },
interruptibleBy = { "QiBolt" },
```

Pressing Q while holding F now ends the meditation and fires.

## Aim and bind the bolt

On the client, the generated policy in `src/client/ActionInputPolicies/QiBolt.luau` returns placeholder zeros. Aim from the character toward the mouse instead, with a small client module, `src/client/Aim.luau`:

```lua title="src/client/Aim.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Aim = {}

function Aim.FromMouse(view: KRF.ActorView): { X: number, Y: number, Z: number }
	local camera: Camera = assert(Workspace.CurrentCamera, "No camera")
	local mouse: Vector2 = UserInputService:GetMouseLocation()
	local ray: Ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	local model: Model? = view:GetModel()
	local root: BasePart? = if model ~= nil then model:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
	local origin: Vector3 = if root ~= nil then root.Position else ray.Origin
	local direction: Vector3 = (ray.Origin + ray.Direction * 500 - origin).Unit

	return { X = direction.X, Y = direction.Y, Z = direction.Z }
end

return Aim
```

Then return its result from the policy:

```lua title="src/client/ActionInputPolicies/QiBolt.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Aim = require(script.Parent.Parent.Aim)

local QiBolt: KRF.ActionInputPolicies = {
	QiBolt = {
		startParameters = function(context: KRF.ActionInputContext): {
			X: number,
			Y: number,
			Z: number,
		}
			return Aim.FromMouse(context.actor)
		end,
	},
}

return QiBolt
```

KRF calls `startParameters` at the moment the player presses the key, and `context.actor` is the ActorView of the character pressing it.

Bind Q to a second ability slot in `src/client/Controls/Keybinds.luau`, next to `AbilitySlot1`:

```lua
AbilitySlot2 = {
	context = "Gameplay",
	type = Enum.InputActionType.Bool,
	bindings = {
		Keyboard = { keyCode = Enum.KeyCode.Q },
		Gamepad = { keyCode = Enum.KeyCode.ButtonY },
	},
},
```

and put the bolt in that slot in `src/client/Controls/Loadout.luau`:

```lua
local SLOTS: { string } = { "AbilitySlot1", "AbilitySlot2" }
```

```lua
local equipped: { [string]: string } = {
	AbilitySlot1 = "Meditate",
	AbilitySlot2 = "QiBolt",
}
```

Finally, show Vitality in the HUD's `status` function:

```lua
local resources: KRF.ResourcesView = view:GetResources()
local text: string = `{meter(resources, "Qi")} · {meter(resources, "Vitality")}`
```

## Checkpoint

The bolt needs a second player. In Studio's Test tab, set Clients and Servers to a local server with two players and start it. In one player's window, meditate until you have some Qi, aim at the other player and press Q.

The target loses 20 Vitality and walks at half speed for a moment, and you lose 15 Qi. Pressing Q again right away does nothing until the cooldown refills two seconds later. Holding F and pressing Q stops the meditation and fires. The bolt has no visible effect yet; chapter 10 draws it.

## Next

[Knock out cultivators](./knock-out) decides what happens when Vitality runs out.
