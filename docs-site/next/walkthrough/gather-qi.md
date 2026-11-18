---
title: Gather Qi
sidebar_label: 3. Gather Qi
sidebar_position: 3
description: Turn the starter's Energy meter into Qi, show it as a bar, and add a spirit spring that restores it.
---

# Gather Qi

Cultivators spend Qi on techniques and breakthroughs, so Qi has to exist before anything can cost it. In this chapter you turn the starter's Energy meter into Qi. Qi trickles in on its own, fills much faster while the player focuses, and tops up at a spirit spring. You'll also draw it on screen as a bar.

## Before you start

You need a project created with `create-krf`, using the default Full project type, with the starter files unchanged. `npm run dev` should open the place in Roblox Studio, and pressing Play should spawn your character. The starter's `src/server/PlayerActors.luau` registers each character as an Actor, and Qi belongs to that Actor.

## How the starter's Energy works

The starter already has a meter. `src/server/Resources/Energy.luau` defines Energy as a Resource, a per-Actor value that stays between a minimum and a maximum and can regenerate. Its regeneration rate comes from the `EnergyRegen` Property, which starts at 0. Holding F starts the starter's Focus Action, Focus applies the Focused Tag, and Focused adds 10 to `EnergyRegen` while it lasts. That's why Energy only fills while you hold F.

Qi needs two changes. It should trickle in when the player isn't focusing, and its maximum should be a Property too, so that breakthroughs can raise it in a later chapter.

## Turn Energy into Qi

Create the Property for the maximum:

```bash
npm run createProperty -- --name MaxQi --default 100
```

The generator notes that `MaxQi` isn't auto-assigned. You can ignore that, because an Actor automatically gets every Property its Resources read.

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

`initialValue = 0` makes new cultivators start empty; without it they would start full. `ClientVisible` sends Qi to every connected client, so other players' clients receive your Qi as well. KRF has no owner-only setting. `ServerOnly` would keep Qi off every client, including your own, and the bar you build next couldn't read it.

The Focused Tag still adds to `EnergyRegen`. Point it at `QiRegen` in `src/server/Tags/Focused.luau`:

```lua title="src/server/Tags/Focused.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Focused: KRF.TagDefinition = {
	id = "Focused",
	duplicateBehavior = "Ignore",
	visibility = "ClientVisible",
	properties = { QiRegen = { add = 10 } },
}

return Focused
```

The starter loads every module in these folders at startup, so there's nothing to register by hand.

## Show Qi as a bar

The starter's `EnergyDisplay` reads a Resource named Energy, which no longer exists. Delete `src/client/EnergyDisplay.luau` and create `src/client/QiDisplay.luau`:

```lua title="src/client/QiDisplay.luau"
--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local KRF = require(ReplicatedStorage.Packages.KRF)
local LocalCharacter = require(script.Parent.LocalCharacter)

local QiDisplay = {}

function QiDisplay.Start(): ()
	local gui: ScreenGui = Instance.new("ScreenGui")
	gui.Name = "QiDisplay"
	gui.ResetOnSpawn = false

	local bar: Frame = Instance.new("Frame")
	bar.Position = UDim2.new(0, 16, 1, -56)
	bar.Size = UDim2.fromOffset(200, 32)
	bar.BackgroundColor3 = Color3.new(0, 0, 0)
	bar.BackgroundTransparency = 0.4
	bar.Parent = gui

	local fill: Frame = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(80, 200, 255)
	fill.BorderSizePixel = 0
	fill.Parent = bar

	local label: TextLabel = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextSize = 18
	label.Text = "Qi"
	label.Parent = bar

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	RunService.RenderStepped:Connect(function()
		local view: KRF.ActorView? = LocalCharacter.Get()
		local qi: KRF.ResourceSnapshot? = if view ~= nil then view:GetResources():GetResource("Qi") else nil

		if qi == nil or qi.max <= qi.min then
			return
		end

		fill.Size = UDim2.fromScale((qi.current - qi.min) / (qi.max - qi.min), 1)
		label.Text = `Qi {math.floor(qi.current)}/{qi.max}`
	end)
end

return QiDisplay
```

The bar reads Qi every frame because the server doesn't send a message for each regeneration step. Each client estimates the current value from the last value the server sent, the time since then and the rate, and `GetResource` returns that estimate. The view also has an `OnResourceChanged` event, but it fires only when the server sends a new value, such as after a restore, so a bar redrawn only from that event would stand still while Qi regenerates.

In `src/client/Startup.client.luau`, replace the two `EnergyDisplay` lines:

```lua title="src/client/Startup.client.luau"
local QiDisplay = require(script.Parent.QiDisplay)

-- ... after KRF.Client.Init succeeds:
QiDisplay.Start()
```

### Checkpoint

Run `npm run dev` and press Play. The bar starts empty and fills at 1 Qi per second. Hold F and it fills at 11 per second until you let go.

If the game doesn't start, the Output window shows `KRF server startup failed` followed by the system and the reason. `Resource: UnknownPropertyId:MaxQi` means the `MaxQi` module is missing or misnamed, and `Tag: UnknownPropertyId:EnergyRegen` means `Focused.luau` still points at the old Property.

## Add a spirit spring

The spring gives players a second source of Qi: stepping into it restores 25 Qi, at most once every 5 seconds per player. Create `src/server/SpiritSpring.luau`:

```lua title="src/server/SpiritSpring.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local KRF = require(ReplicatedStorage.Packages.KRF)

local QI_PER_VISIT: number = 25
local COOLDOWN_SECONDS: number = 5

local SpiritSpring = {}

local resting: { [Model]: boolean } = {}

local function visit(character: Model): ()
	local actor: KRF.Actor? = KRF.ActorRegistry.GetActorByModel(character)
	local resources: KRF.ResourceController? = if actor ~= nil
		then actor:GetController("ResourceController") :: KRF.ResourceController?
		else nil

	if resources == nil or resting[character] then
		return
	end

	local restored: boolean, reason: string? = resources:Restore("Qi", QI_PER_VISIT)

	if not restored then
		warn(`The spirit spring could not restore Qi: {reason}`)
		return
	end

	resting[character] = true
	task.delay(COOLDOWN_SECONDS, function()
		resting[character] = nil
	end)
end

function SpiritSpring.Start(): ()
	local spring: Part = Instance.new("Part")
	spring.Name = "SpiritSpring"
	spring.Anchored = true
	spring.CanCollide = false
	spring.Size = Vector3.new(8, 1, 8)
	spring.Position = Vector3.new(0, 0.5, -16)
	spring.Material = Enum.Material.Neon
	spring.Color = Color3.fromRGB(80, 200, 255)
	spring.Parent = Workspace

	spring.Touched:Connect(function(hit: BasePart)
		local character: Model? = hit:FindFirstAncestorOfClass("Model")

		if character ~= nil then
			visit(character)
		end
	end)
end

return SpiritSpring
```

Only the server can change Qi, so the spring runs on the server and goes through the Actor's `ResourceController`. It calls the controller directly because nobody is paying for anything; the world is handing out Qi. When a technique spends Qi in a later chapter, the price goes in that Action's `costs`, and KRF checks and charges it when it accepts the Action.

`Restore` stops at the maximum, so a full cultivator can step in and nothing changes. It returns `false` and a reason only when the Actor has no Qi or the amount is invalid, which would be a bug, so the spring warns about it.

Start the spring in `src/server/Startup.server.luau`, after `PlayerActors.Start()`:

```lua title="src/server/Startup.server.luau"
local SpiritSpring = require(script.Parent.SpiritSpring)

-- ... after PlayerActors.Start():
SpiritSpring.Start()
```

### Checkpoint

Press Play and walk forward onto the glowing pad. The bar jumps by 25. Stepping in again does nothing until 5 seconds have passed.

## Check your work

```bash
npm run check
npm run test:studio
```

`npm run check` checks formatting, lints and type-checks your code. `npm run test:studio` plays the game with a server and two clients and confirms that every player becomes an Actor; an invalid definition makes it fail with the reason.

## Exercise

Make the spring refill Qi completely instead of adding 25.

<details>
<summary>Hint</summary>

`ResourceController:GetMax("Qi")` returns the Actor's maximum, and `SetCurrent` sets an exact value.

</details>

<details>
<summary>Solution</summary>

Replace the `Restore` call in `visit`:

```lua
local restored: boolean, reason: string? = resources:SetCurrent("Qi", resources:GetMax("Qi") or 0)
```

`SetCurrent` clamps into the bounds, so the value can never go past the maximum. Read the Actor's maximum instead of writing 100, because a later chapter raises `MaxQi`.

</details>

## Next

The next chapter turns Focus into meditation and adds the first technique that spends Qi. [Resources](/reference/resources) covers what this chapter skipped, including cooldowns, charges and what happens to the current value when the maximum changes.
