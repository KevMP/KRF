---
title: Gather Qi
sidebar_label: 3. Gather Qi
sidebar_position: 3
description: Give every cultivator a Qi meter that fills over time, shows on screen and refills at a spirit spring.
---

# Gather Qi

Your cultivators can spawn and walk around, but they have nothing to cultivate yet. In this chapter you give each of them Qi, the energy later chapters spend on techniques and breakthroughs. By the end, every player has a Qi bar that fills slowly on its own, and a glowing spirit spring tops it up when they step in.

KRF keeps per-player meters like Qi as Resources, and you'll build Qi on top of two Properties so later chapters can raise its limits.

## Before you start

This chapter continues the game from the earlier chapters. You need:

- A KRF project created with `create-krf`, using the default Full project type.
- The starter files unchanged, apart from what earlier chapters asked you to change.
- `npm run dev` working: Roblox Studio opens the place and you can press Play.

You should also know that each player's character becomes an Actor when it spawns; the starter's `src/server/PlayerActors.luau` registers it. Every per-player value in this chapter belongs to that Actor.

## What Qi is

Qi comes down to three numbers: how much a cultivator has now, how much they can hold, and how fast it comes back. KRF splits these between two systems:

| Number | KRF system | Why |
| --- | --- | --- |
| Current Qi | A Resource named `Qi` | It is spent, restored and refilled |
| Maximum Qi | A Property named `MaxQi` | Breakthroughs will raise it in a later chapter |
| Qi per second | A Property named `QiRegen` | Meditation will boost it in a later chapter |

A Resource is a meter, a current value kept between a minimum and a maximum. A Property is a number that other systems can modify. If the maximum and the rate are Properties now, later chapters can change them without touching Qi itself.

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

`defaultBaseValue` is the number every Actor starts with. The generator will mention that these Properties aren't auto-assigned. You can ignore that, because the Qi Resource gives both Properties to every Actor that has Qi.

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

| Line | What it does |
| --- | --- |
| `max = { propertyName = "MaxQi" }` | The maximum follows each Actor's `MaxQi`. A fixed maximum would be `{ value = 100 }` |
| `initialValue = 0` | Cultivators start empty. Without this line they would start full |
| `visibility = "ClientVisible"` | Clients can read Qi |
| `autoAssign = true` | Every Actor gets Qi when it registers |
| `regen = { rate = ... }` | Qi rises by `QiRegen` per second, up to the maximum |

The definition has no `min` line because a Resource's minimum defaults to 0.

`ClientVisible` sends Qi to every player, so each cultivator can see how much Qi the others carry. That suits a game where you sense an opponent's strength. A value only its owner should see would be `"ServerOnly"`.

The starter loads every module in `src/server/Resources` and `src/server/Properties` at startup, so you don't register anything by hand. Leave the starter's Energy meter alone for now; a later chapter replaces it.

### Checkpoint

Run `npm run dev` and press Play. The game starts as before, with no errors in the Output window. You can't see Qi yet, but every character already has it and it's filling.

If the Output window shows `KRF server startup failed (Resource: ...)`, the text after the colon names the problem. `UnknownPropertyId:MaxQi`, for example, means the `MaxQi` Property module is missing or misnamed.

## Show Qi on screen

Clients read an Actor's Resources through its ActorView, the client's read-only copy of the Actor. The starter's `LocalCharacter` module finds the view for your own character.

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

The bar reads Qi every frame because the server doesn't send a message each time Qi regenerates. The client estimates the current value from the last value the server sent, the time since then and the regeneration rate, and `GetResource` returns that estimate. Reading it every frame gives a bar that fills smoothly.

Start the display after KRF starts on the client. In `src/client/Startup.client.luau`, require the module next to the others and call `Start` at the end:

```lua title="src/client/Startup.client.luau"
local QiDisplay = require(script.Parent.QiDisplay)

-- ... after KRF.Client.Init succeeds:
QiDisplay.Start()
```

### Checkpoint

Press Play. A blue bar appears above the Energy label and fills from `Qi 0/100` to `Qi 100/100` in about 100 seconds.

## Add a spirit spring

Waiting 100 seconds for a full bar is slow, so give players a faster way to gather Qi. A glowing spring restores 25 Qi when a player steps in, at most once every 5 seconds.

Only the server can change Qi, so the spring is server code. When something touches it, the spring looks up the Actor for that character, gets the Actor's `ResourceController` and calls `Restore`.

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

`KRF.ActorRegistry.GetActorByModel` returns `nil` for anything that isn't an Actor, such as a loose part, so only cultivators gain Qi. For a cultivator, `actor:GetController("ResourceController")` returns the object that owns that Actor's Resources; each Actor has its own.

`Restore` adds Qi and stops at the maximum, so a cultivator who is already full can step in and nothing happens. It returns whether it worked and, if not, why. It fails only if the Actor has no Qi or the amount is invalid, and the spring warns in that case so a mistake doesn't go unnoticed.

The spring calls the `ResourceController` directly because it's the world handing out Qi to whoever walks in. Actions are for abilities a player chooses to use, and they carry their own costs and rules. When a technique spends Qi in a later chapter, the cost goes on the Action instead.

Start the spring after KRF starts on the server. In `src/server/Startup.server.luau`:

```lua title="src/server/Startup.server.luau"
local SpiritSpring = require(script.Parent.SpiritSpring)

-- ... after PlayerActors.Start():
SpiritSpring.Start()
```

### Checkpoint

Press Play and walk forward to the glowing pad. Each time you step in, the bar jumps by 25, as long as 5 seconds have passed since your last visit.

## Flash the bar when Qi arrives

A burst from the spring should look different from slow regeneration, so make the bar flash when it happens. A per-frame read can't tell the two apart, but the view's `OnResourceChanged` event can, because it fires only when the server sends a new value and never for regeneration.

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

`LocalCharacter.Observe` calls the function for each new character, including after a respawn. When a character goes away, KRF disconnects the listeners on its old view, so you have nothing to clean up.

The checks at the top skip two kinds of change that aren't bursts. A `"Baseline"` change arrives when the client receives the Actor's full state, for example after reconnecting, so the code only reacts to `"Commit"`. A change with no `before` snapshot is Qi being assigned for the first time.

### Checkpoint

Step into the spring: the bar flashes white as it jumps. Standing still while Qi regenerates never flashes.

## Check your work

Run the project's checks:

```bash
npm run check
npm run test:studio
```

`npm run check` checks formatting, lints and type-checks your code. `npm run test:studio` starts a server and two clients in Studio and confirms that KRF starts and every player becomes an Actor. A mistake in a definition, such as a misspelled Property, makes it fail with the reason.

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

`SetCurrent` clamps into the bounds, so the value can never go past the maximum. Read the Actor's maximum instead of writing 100, because later chapters raise `MaxQi`.

</details>

## What you learned

Qi is a Resource: a per-Actor meter with a current value, bounds and regeneration. Its maximum and rate come from the `MaxQi` and `QiRegen` Properties, which later chapters will change. `autoAssign` gave it to every cultivator, and `initialValue` made them start empty.

On the server, the spring changed Qi through the Actor's `ResourceController`, which also has `SetCurrent`, `Drain` and `Spend`. On the client, the HUD reads the `ResourcesView` estimate every frame and uses `OnResourceChanged` only to react to real changes.

[Resources](/next/reference/resources) covers the rest, including cooldowns and charges, and the [Resources API](/next/reference/resources-api) lists every method and failure reason.

## Next

In the next chapter, cultivators meditate. Meditation is an Action that raises `QiRegen` while the player holds a key, and it leads to your first technique that spends Qi.
