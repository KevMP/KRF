---
title: Stand still while meditating
sidebar_label: 3. Stand still
sidebar_position: 4
description: Write a Controller that applies the resolved WalkSpeed Property to each character's Humanoid.
---

# Stand still while meditating

KRF already knows a meditating cultivator's `WalkSpeed` is 0. It doesn't move characters, so nothing applies that number to the Humanoid. In this chapter you write the code that does, as a Controller, and every speed change later in the game will go through it.

## Controllers

A Controller holds state or behavior for one Actor. KRF creates one of each Controller for every Actor when the Actor registers and destroys them when it unregisters. The Resources, Tags and Actions you've used so far are KRF's own Controllers; you can add yours next to them.

Create one named Movement that depends on the Property Controller:

```bash
npm run createController -- --name Movement --depends-on PropertyController
```

The generator writes `src/server/Controllers/Movement.luau` and adds a `controllers` catalog to `Server.Init` in `Startup.server.luau`. Replace the module's contents:

```lua title="src/server/Controllers/Movement.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Movement: KRF.ControllerDefinition = {
	key = "Movement",
	factory = function(actor: KRF.Actor): KRF.Controller
		local properties = actor:GetController("PropertyController") :: KRF.PropertyController

		local function apply(): ()
			local humanoid: Humanoid? = if actor.model ~= nil
				then actor.model:FindFirstChildOfClass("Humanoid")
				else nil
			local walkSpeed: number? = properties:GetResolvedProperty("WalkSpeed")

			if humanoid ~= nil and walkSpeed ~= nil then
				humanoid.WalkSpeed = walkSpeed
			end
		end

		local connection: KRF.Connection = properties.OnResolvedPropertyChanged:Connect(
			function(_actor: KRF.Actor, propertyName: string)
				if propertyName == "WalkSpeed" then
					apply()
				end
			end
		)

		apply()

		return {
			Destroy = function(): ()
				connection:Disconnect()
			end,
		}
	end,
	dependsOn = { "PropertyController" },
}

return Movement
```

`factory` runs once per Actor and returns the Controller. `dependsOn` makes KRF create the Property Controller first, so the factory can look it up. The returned `Destroy` runs when the Actor unregisters, which is where the connection is cleaned up.

`OnResolvedPropertyChanged` fires whenever a Property's final value changes, after every Tag modifier is applied. Movement copies `WalkSpeed` onto the Humanoid at that moment and once at the start. Setting the Humanoid's `WalkSpeed` on the server replicates to the player's client, which moves the character.

## Checkpoint

Press Play and hold F. You can't walk while you meditate, and you can again as soon as you let go.

## Next

[Fire a Qi bolt](./fire-a-qi-bolt) gives cultivators something to spend Qi on.
