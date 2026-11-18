---
title: Draw techniques
sidebar_label: 10. Draw techniques
sidebar_position: 11
description: Use a Hint to tell every client when a technique fires, and draw a beam for it.
---

# Draw techniques

Bolts and sect techniques still have no visible effect, so a player who gets hit has no idea where it came from. In this chapter every client draws a short beam whenever a technique fires.

## Hints

Only the server knows where a technique went, so it has to tell clients. A replication domain is the wrong tool for this: a beam isn't state a late joiner needs, and KRF would keep it up to date for no reason. A Command goes the wrong way. A Hint is a one-off, cosmetic message, and KRF may drop it under load, which is fine for a beam.

```bash
npm run createHint -- --name TechniqueCast --direction ServerToClient --target Actor --mode Pulse --payload-field X:F32 --payload-field Y:F32 --payload-field Z:F32 --payload-field Length:F32
```

The Hint names the Actor that fired, the direction and how far the beam reaches. `Pulse` means each message is a separate occurrence; `Latest` would keep only the newest value, which suits things like where a player is looking.

## Send it

Every technique already goes through `Combat.Cast`, so that's the one place to send the Hint. Update `src/server/Combat.luau`:

```lua title="src/server/Combat.luau"
--!strict
local Players = game:GetService("Players")
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
	local length: number = if result ~= nil then (result.Position - root.Position).Magnitude else range

	for _, player: Player in Players:GetPlayers() do
		KRF.ServerHintRuntime.SendTo(
			player,
			"TechniqueCast",
			actor,
			{ X = aim.X, Y = aim.Y, Z = aim.Z, Length = length }
		)
	end

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

`SendTo` sends to one player at a time, so the server decides who receives a Hint. Here it's everyone. The beam stops where the raycast hit, or at full range if it missed.

## Draw it

Create `src/client/Effects.luau`:

```lua title="src/client/Effects.luau"
--!strict
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Effects = {}

function Effects.Start(): ()
	KRF.ClientHintRuntime.OnHintReceived:Connect(function(receipt: KRF.HintReceived)
		local model: Model? = if receipt.actorView ~= nil then receipt.actorView:GetModel() else nil
		local root: BasePart? = if model ~= nil then model:FindFirstChild("HumanoidRootPart") :: BasePart? else nil

		if receipt.hintId ~= "TechniqueCast" or root == nil then
			return
		end

		local payload: { X: number, Y: number, Z: number, Length: number } = receipt.payload
		local direction: Vector3 = Vector3.new(payload.X, payload.Y, payload.Z)

		local beam: Part = Instance.new("Part")
		beam.Anchored = true
		beam.CanCollide = false
		beam.CanQuery = false
		beam.CanTouch = false
		beam.Material = Enum.Material.Neon
		beam.Color = Color3.fromRGB(80, 200, 255)
		beam.Size = Vector3.new(0.3, 0.3, payload.Length)
		beam.CFrame = CFrame.lookAt(root.Position, root.Position + direction) * CFrame.new(0, 0, -payload.Length / 2)
		beam.Parent = Workspace

		Debris:AddItem(beam, 0.15)
	end)
end

return Effects
```

The receipt's `actorView` is the ActorView of the cultivator who fired, so the beam starts at their character. It's optional because a Hint can also target no Actor. If a Hint arrives before the client has received its Actor, KRF drops it rather than holding it, which costs one beam at most.

Start it in `src/client/Startup.client.luau`:

```lua
local Effects = require(script.Parent.Effects)
```

```lua
Effects.Start()
```

## Checkpoint

In a two-player test, fire a bolt. Both players see a blue beam from the caster toward the mouse, ending where it hit.

## Next

[Test the game](./test-the-game) adds automated checks.
