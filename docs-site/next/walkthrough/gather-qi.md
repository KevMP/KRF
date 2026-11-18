---
title: Gather Qi
sidebar_label: 1. Gather Qi
sidebar_position: 2
description: Turn the starter's Energy into Qi, a Resource whose limit and rate come from Properties.
---

# Gather Qi

Cultivators spend Qi on everything they do, so it comes first. Qi works like the starter's Energy with two differences: it trickles in even when nobody is focusing, and its maximum must be able to grow when a cultivator reaches a higher realm. In this chapter you turn Energy into Qi and replace the Energy label with a small HUD the rest of the walkthrough builds on.

## Resources and Properties

The starter's Energy is a Resource: a value each Actor holds between a minimum and a maximum, which can be spent, restored and regenerated. Its regeneration rate comes from a Property, a number other systems can modify. That's how the Focused Tag speeds Energy up; it adds 10 to the `EnergyRegen` Property, and the Resource follows.

Qi needs its maximum to change too, so the maximum becomes a Property as well. Create it:

```bash
npm run createProperty -- --name MaxQi --default 100
```

The generator will mention that `MaxQi` isn't auto-assigned. That's fine: an Actor automatically gets every Property its Resources read.

## Turn Energy into Qi

Rename `src/server/Properties/EnergyRegen.luau` to `QiRegen.luau` and give it a base rate of 1 Qi per second:

```lua title="src/server/Properties/QiRegen.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local QiRegen: KRF.PropertyDefinition = {
	id = "QiRegen",
	defaultBaseValue = 1,
}

return QiRegen
```

Rename `src/server/Resources/Energy.luau` to `Qi.luau` and point it at the two Properties:

```lua title="src/server/Resources/Qi.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Qi: KRF.ResourceDefinition = {
	id = "Qi",
	max = { propertyName = "MaxQi" },
	initialValue = 0,
	regen = { rate = { propertyName = "QiRegen" } },
	visibility = "ClientVisible",
	autoAssign = true,
}

return Qi
```

`initialValue = 0` makes new cultivators start empty; without it they'd start full. `ClientVisible` sends Qi to every connected client, which lets your HUD read it and lets other players' clients see it too. There's no owner-only setting for Resources; `ServerOnly` would keep Qi off every client, including yours.

The Focused Tag still adds to `EnergyRegen`. In `src/server/Tags/Focused.luau`, change its modifier:

```lua title="src/server/Tags/Focused.luau"
properties = { QiRegen = { add = 10 } },
```

## Show Qi

Rename `src/client/EnergyDisplay.luau` to `Hud.luau` and replace its contents:

```lua title="src/client/Hud.luau"
--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local KRF = require(ReplicatedStorage.Packages.KRF)
local LocalCharacter = require(script.Parent.LocalCharacter)

local Hud = {}

local function meter(resources: KRF.ResourcesView, resourceId: string): string
	return `{resourceId} {math.floor(resources:GetCurrent(resourceId) or 0)}/{resources:GetMax(resourceId) or 0}`
end

local function status(view: KRF.ActorView): string
	return meter(view:GetResources(), "Qi")
end

function Hud.Start(): ()
	local player: Player = Players.LocalPlayer

	local gui: ScreenGui = Instance.new("ScreenGui")
	gui.Name = "Hud"
	gui.ResetOnSpawn = false

	local label: TextLabel = Instance.new("TextLabel")
	label.Name = "Status"
	label.Position = UDim2.new(0, 16, 1, -56)
	label.Size = UDim2.fromOffset(420, 40)
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.4
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextSize = 20
	label.Parent = gui

	gui.Parent = player:WaitForChild("PlayerGui")

	RunService.RenderStepped:Connect(function()
		local view: KRF.ActorView? = LocalCharacter.Get()
		local text: string = if view ~= nil then status(view) else ""

		if label.Text ~= text then
			label.Text = text
		end
	end)
end

return Hud
```

The label code is the starter's. What changed is the `status` function, which builds the label's text from the character's ActorView. Later chapters only add lines to `status`.

The HUD redraws every frame because the server doesn't send a message each time Qi regenerates. The client estimates Qi from the last value the server sent, the time since then and the rate, so `GetCurrent` moves smoothly on its own.

In `src/client/Startup.client.luau`, require `Hud` where it required `EnergyDisplay`, and start it the same way:

```lua
local Hud = require(script.Parent.Hud)
```

```lua
Hud.Start()
```

## Checkpoint

Press Play. The label reads `Qi 0/100` and rises by 1 every second. Hold F and it climbs 11 per second until you let go.

If the game doesn't start, the Output window shows `KRF server startup failed` followed by the system and a reason. `Resource: UnknownPropertyId:MaxQi` means the `MaxQi` module is missing or misnamed. `Tag: UnknownPropertyId:EnergyRegen` means `Focused.luau` still points at the old Property.

## Next

[Meditate](./meditate) turns the starter's Focus into meditation.
