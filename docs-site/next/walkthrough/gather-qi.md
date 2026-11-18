---
title: Gather Qi
sidebar_label: 3. Gather Qi
sidebar_position: 3
description: Give every cultivator a Qi meter that fills over time, shows on screen and refills at a spirit spring.
---

# Gather Qi

Every cultivator in our game gathers Qi, the energy later chapters spend on techniques and breakthroughs. In this chapter you give every player a Qi meter that fills slowly, draw it on screen, and add a spirit spring that refills it.

Along the way you'll learn how KRF stores per-player meters as **Resources**, how **Properties** can drive them, and how the server and clients each work with them.

## Before you start

This chapter continues the game from the earlier chapters. You need:

- A KRF project created with `create-krf`, using the default Full project type.
- The starter files unchanged, apart from what earlier chapters asked you to change.
- `npm run dev` working: Roblox Studio opens the place and you can press Play.

You should also know that each player's character becomes an **Actor** when it spawns. The starter's `src/server/PlayerActors.luau` registers it. Every per-player value in this chapter belongs to that Actor.

## What Qi is

Qi has three numbers: how much a cultivator has now, how much they can hold, and how fast it comes back. KRF splits these between two systems:

| Number | KRF system | Why |
| --- | --- | --- |
| Current Qi | A Resource named `Qi` | It is spent, restored and refilled |
| Maximum Qi | A Property named `MaxQi` | Breakthroughs will raise it in a later chapter |
| Qi per second | A Property named `QiRegen` | Meditation will boost it in a later chapter |

A Resource is a meter: a current value kept between a minimum and a maximum. A Property is a number other systems can modify. Making the maximum and the rate Properties now means later chapters can change them without touching Qi itself.

## Create the Properties

Run both generator commands from the project folder:

```bash
npm run createProperty -- --name MaxQi --default 100
npm run createProperty -- --name QiRegen --default 1
```

Each command writes one module to `src/server/Properties`:

```lua title="src/server/Properties/MaxQi.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local MaxQi: KRF.PropertyDefinition = {
	id = "MaxQi",
	defaultBaseValue = 100,
}

return MaxQi
```

`defaultBaseValue` is the number every Actor starts with. The generator mentions that these Properties are not auto-assigned. That's intended: the Qi Resource assigns them to every Actor that has Qi.

## Create the Qi Resource

```bash
npm run createResource -- --name Qi --max MaxQi --initial 0 --regen QiRegen --visibility ClientVisible
```

```lua title="src/server/Resources/Qi.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Qi: KRF.ResourceDefinition = {
	id = "Qi",
	max = { propertyName = "MaxQi" },
	initialValue = 0,
	visibility = "ClientVisible",
	autoAssign = true,
	regen = { rate = { propertyName = "QiRegen" } },
}

return Qi
```

Line by line:

- **`max = { propertyName = "MaxQi" }`**: the maximum follows each Actor's `MaxQi`. A fixed maximum would be `{ value = 100 }`.
- **`initialValue = 0`**: cultivators start empty. Without it they would start full.
- **`visibility = "ClientVisible"`**: clients can read Qi. Every player can see every other cultivator's Qi, which suits a game where you can sense an opponent's strength. A secret value would be `"ServerOnly"`.
- **`autoAssign = true`**: every Actor gets Qi when it registers.
- **`regen`**: Qi rises by `QiRegen` per second, up to the maximum.

There is no minimum line. A Resource's minimum defaults to 0.

The starter loads every module in `src/server/Resources` and `src/server/Properties` at startup, so there is nothing to register by hand. The starter's own Energy meter stays as it is; a later chapter replaces it.

### Checkpoint

Run `npm run dev` and press Play. The game should start as before, with no errors in the Output window. You can't see Qi yet, but every character now has it and it is already filling.

If the Output window shows `KRF server startup failed (Resource: ...)`, the reason names the problem. For example, `UnknownPropertyId:MaxQi` means the `MaxQi` Property module is missing or misnamed.

## Show Qi on screen

Clients read an Actor's Resources through its **ActorView**, the client's read-only copy of the Actor. The starter's `LocalCharacter` module finds the view for your own character.

Create `src/client/QiDisplay.luau`:

```lua title="src/client/QiDisplay.luau"
--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local KRF = require(ReplicatedStorage.Packages.KRF)
local LocalCharacter = require(script.Parent.LocalCharacter)

local QI_COLOR: Color3 = Color3.fromRGB(80, 200, 255)
local FLASH_COLOR: Color3 = Color3.new(1, 1, 1)

local QiDisplay = {}

function QiDisplay.Start(): ()
	local gui: ScreenGui = Instance.new("ScreenGui")
	gui.Name = "QiDisplay"
	gui.ResetOnSpawn = false

	local bar: Frame = Instance.new("Frame")
	bar.Position = UDim2.new(0, 16, 1, -104)
	bar.Size = UDim2.fromOffset(200, 32)
	bar.BackgroundColor3 = Color3.new(0, 0, 0)
	bar.BackgroundTransparency = 0.4
	bar.Parent = gui

	local fill: Frame = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = QI_COLOR
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

The bar reads Qi every frame. That's deliberate: the server doesn't send a message each time Qi regenerates. Instead, the client estimates the current value from the last value the server sent, the time since then and the regeneration rate. `GetResource` returns that estimate, so reading it every frame gives a smoothly filling bar.

Start the display after KRF starts on the client. In `src/client/Startup.client.luau`, require the module next to the others and call `Start` at the end:

```lua title="src/client/Startup.client.luau"
local QiDisplay = require(script.Parent.QiDisplay)

-- ... after KRF.Client.Init succeeds:
QiDisplay.Start()
```

### Checkpoint

Press Play. A blue bar appears above the Energy label and fills from `Qi 0/100` to `Qi 100/100` in about 100 seconds.

## Add a spirit spring

Now give players a faster way to gather Qi: a glowing spring that restores 25 Qi when they step in, at most once every 5 seconds.

Restoring Qi is a server decision, so the spring is server code. It finds the Actor for the character that touched it, gets the Actor's `ResourceController`, and calls `Restore`.

Create `src/server/SpiritSpring.luau`:

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

A few things to notice:

- **`KRF.ActorRegistry.GetActorByModel`** returns `nil` for anything that isn't an Actor, such as a loose part, so only cultivators gain Qi.
- **`actor:GetController("ResourceController")`** gets the object that owns this Actor's Resources. Each Actor has its own.
- **`Restore`** adds Qi and stops at the maximum. A full cultivator can step in without error; nothing changes.
- **`Restore` returns whether it worked, and why not.** It fails if the Actor has no Qi or the amount is invalid. The spring warns instead of failing silently.

Why not make the spring an Action? Actions are abilities an Actor chooses to use, with their own costs and rules. The spring is the world giving Qi to whoever walks in, so calling the `ResourceController` directly is the right tool. When an ability spends Qi in a later chapter, it will declare the cost on the Action instead.

Start the spring after KRF starts on the server. In `src/server/Startup.server.luau`:

```lua title="src/server/Startup.server.luau"
local SpiritSpring = require(script.Parent.SpiritSpring)

-- ... after PlayerActors.Start():
SpiritSpring.Start()
```

### Checkpoint

Press Play and walk forward to the glowing pad. Each time you step in, the bar jumps by 25, as long as 5 seconds have passed since your last visit.

## Flash the bar when Qi arrives

The bar reads Qi every frame, but some moments deserve a reaction: the spring's burst should make the bar flash. A per-frame read can't tell a burst from regeneration. The view's `OnResourceChanged` event can: it fires only when the server sends a new value, never for regeneration.

Add this at the end of `QiDisplay.Start`:

```lua title="src/client/QiDisplay.luau"
	LocalCharacter.Observe(function(view: KRF.ActorView)
		view:GetResources().OnResourceChanged:Connect(function(change: KRF.ResourceViewChange)
			local before: KRF.ResourceSnapshot? = change.previous
			local after: KRF.ResourceSnapshot? = change.current

			if change.resourceId ~= "Qi" or change.source ~= "Commit" or before == nil or after == nil then
				return
			end

			if after.current > before.current then
				fill.BackgroundColor3 = FLASH_COLOR
				task.delay(0.15, function()
					fill.BackgroundColor3 = QI_COLOR
				end)
			end
		end)
	end)
```

- **`LocalCharacter.Observe`** calls the function for each new character, including after a respawn. When a character goes away, KRF disconnects listeners on its old view, so there's nothing to clean up.
- **`change.source ~= "Commit"`** ignores `"Baseline"` changes, which happen when the client receives the Actor's full state, for example after reconnecting. Those aren't events in the game.
- **`before == nil`** is the moment Qi is first assigned, which isn't a burst either.

### Checkpoint

Step into the spring: the bar flashes white as it jumps. Standing still while Qi regenerates never flashes.

## Check your work

Run the project's checks:

```bash
npm run check
npm run test:studio
```

`npm run check` checks formatting, lints and type-checks your code. `npm run test:studio` starts a server and two clients in Studio and confirms KRF starts and every player becomes an Actor. A mistake in a definition, such as a misspelled Property, fails here with the reason.

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

`SetCurrent` clamps into the bounds, so the value can never go past the maximum. Keep using the Actor's maximum rather than writing 100, because later chapters raise `MaxQi`.

</details>

## What you learned

- A **Resource** is a per-Actor meter with a current value, bounds and optional regeneration.
- **Properties** can supply a Resource's maximum and rate, so other systems can change them later.
- `autoAssign` gives a Resource to every Actor; `initialValue` sets where it starts.
- Server code changes a Resource through the Actor's **`ResourceController`**: `Restore`, `SetCurrent`, `Drain` and `Spend`.
- Clients read Resources through the **`ResourcesView`**: read the estimate every frame for display, and use `OnResourceChanged` for reactions to real changes.

The [Resources reference](/next/reference/resources) covers everything else, including cooldowns, charges and every failure reason.

## Next

In the next chapter, cultivators **meditate**: an Action that raises `QiRegen` while held, and your first technique that spends Qi.
