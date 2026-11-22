---
title: Gather Qi
sidebar_label: 1. Gather Qi
sidebar_position: 2
description: Replace Energy with Qi that regenerates over time and fills faster while holding F.
---

# Gather Qi

You've already got an Energy meter running, so let's build on it. Players will be able to gather Qi slowly on their own, then hold F to gather it faster.

## Set the maximum Qi

Players will start with room for 100 Qi. We'll store that limit in a [Property](/reference/properties/guide) so we can increase it when they reach higher realms.

Run this from your project folder to create `MaxQi`:

```bash
npm run createProperty -- --name MaxQi --default 100
```

The generator will create `src/server/Properties/MaxQi.luau` with a default value of 100.

## Let Qi regenerate

The starter's Energy only regenerates while you hold F. We'll give Qi a base rate of 1 per second so players will be able to gather it without holding a key.

Rename `src/server/Properties/EnergyRegen.luau` to `QiRegen.luau` and replace its contents:

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

## Replace Energy with Qi

Now that we have the limit and rate, we can connect them to Qi. KRF calls a meter like this a Resource: it tracks how much a character currently has and keeps that value within the bounds you set.

Rename `src/server/Resources/Energy.luau` to `Qi.luau` and replace its contents:

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

With `autoAssign = true`, every character will get Qi automatically, along with the two Properties it uses. Setting `visibility = "ClientVisible"` will replicate Qi's state and subsequent changes to every client.

There's one more reference to the old `EnergyRegen` name. The Focused Tag uses it to apply the bonus from holding F. In `src/server/Tags/Focused.luau`, change the modifier to use `QiRegen`:

```lua title="src/server/Tags/Focused.luau"
properties = { QiRegen = { add = 10 } },
```

## Reuse the starter's display

We've already got a working label, so we'll keep it and change the Resource it reads. Rename `src/client/EnergyDisplay.luau` to `Hud.luau`, then rename the `EnergyDisplay` table and its references to `Hud`.

Above `Hud.Start`, add these two functions:

```lua
local function meter(resources: KRF.ResourcesView, resourceId: string): string
	return `{resourceId} {math.floor(resources:GetCurrent(resourceId) or 0)}/{resources:GetMax(resourceId) or 0}`
end

local function status(view: KRF.ActorView): string
	return meter(view:GetResources(), "Qi")
end
```

The `status` function reads Qi from the character's ActorView, which gives client code read-only access to its replicated state. We'll add to this function as we build the rest of the game.

Inside the existing `RenderStepped` callback, replace the block from `local resources` through `local text` with:

```lua
local text: string = status(view)
```

KRF estimates regeneration on the client between server updates, so we'll keep reading Qi every frame to keep the meter moving.

Finally, we need to start the renamed module. In `src/client/Startup.client.luau`, replace the `EnergyDisplay` require with:

```lua
local Hud = require(script.Parent.Hud)
```

Replace `EnergyDisplay.Start()` with:

```lua
Hud.Start()
```

## Try it

Press Play and leave F alone for a moment. Qi should increase by 1 per second. Hold F before the meter fills, and the Focus Action's bonus will bring that up to 11 per second. Release F and watch it slow down again. Qi will stop at `100/100` either way.

## Next

In [Meditate](./meditate), we'll turn the starter's Focus Action into the game's meditation ability.
