---
title: Show realms to everyone
sidebar_label: 4. Show realms
sidebar_position: 5
description: Replicate each character's realm and receive breakthrough events on every client.
---

# Show realms to everyone

Our Cultivation Controller keeps each character's realm on the server. Let's make that state available to clients so players will be able to see their realm beside Qi. We'll also send a breakthrough event to every client and print it in Studio's Output window.

## Define what clients will receive

Qi already replicates because we marked its Resource definition `ClientVisible`. To replicate the realm from our Cultivation Controller, we'll define a replication domain that specifies how KRF reads the state and which clients receive it.

Generate a Cultivation domain:

```bash
npm run createDomain -- --name Cultivation --audience All --state-field Realm:U8 --event "BrokeThrough(Realm:U8)" --observe
```

We'll send the current realm as state and each breakthrough as a `BrokeThrough` event. A client joining late will receive the current realm without replaying earlier breakthrough events.

## Observe changes to the realm

KRF needs a way to detect changes to our Controller. We'll add an `Observe` method so the domain can subscribe to realm changes and disconnect when the Actor is removed. Update `src/server/Controllers/Cultivation.luau`:

```lua title="src/server/Controllers/Cultivation.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Realms = require(ReplicatedStorage.Shared.Realms)

export type Cultivation = KRF.Controller & {
	GetRealm: () -> number,
	IsAtPeak: () -> boolean,
	Advance: () -> (),
	Observe: (listener: (realm: number) -> ()) -> () -> (),
}

local Cultivation: KRF.ControllerDefinition = {
	key = "Cultivation",
	factory = function(actor: KRF.Actor): KRF.Controller
		local properties = actor:GetController("PropertyController") :: KRF.PropertyController
		local realm: number = 1
		local listeners: { (realm: number) -> () } = {}

		local cultivation: Cultivation = {
			GetRealm = function(): number
				return realm
			end,
			IsAtPeak = function(): boolean
				return realm >= #Realms.NAMES
			end,
			Advance = function(): ()
				realm += 1

				for _, listener in table.clone(listeners) do
					listener(realm)
				end

				properties:SetBaseProperty("MaxQi", Realms.MaxQi(realm))
			end,
			Observe = function(listener: (realm: number) -> ()): () -> ()
				table.insert(listeners, listener)

				return function(): ()
					local index: number? = table.find(listeners, listener)

					if index ~= nil then
						table.remove(listeners, index)
					end
				end
			end,
			Destroy = function(): ()
				table.clear(listeners)
			end,
		}

		return cultivation
	end,
	dependsOn = { "PropertyController" },
}

return Cultivation
```

`Advance` will now call the listeners after updating `realm`. Keep that call before `SetBaseProperty`: changing a Property can run other callbacks, so KRF needs the new realm marked for replication first.

## Connect the Controller to the domain

We can now read the realm and observe changes to it. Replace the generated domain in `src/server/ReplicationDomains/Cultivation.luau` with:

```lua title="src/server/ReplicationDomains/Cultivation.luau"
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local CultivationController = require(script.Parent.Parent.Controllers.Cultivation)

local function cultivationOf(actor: KRF.Actor): CultivationController.Cultivation
	return actor:GetController("Cultivation") :: CultivationController.Cultivation
end

local Cultivation: KRF.ReplicationDomainDefinition = {
	id = "Cultivation",
	state = KRF.Schema.Struct({
		Realm = KRF.Schema.U8,
	}),
	events = {
		{
			id = "BrokeThrough",
			payload = KRF.Schema.Struct({
				Realm = KRF.Schema.U8,
			}),
		},
	},
	audience = "All",
	snapshot = function(actor: KRF.Actor): { [string]: any }
		return {
			Realm = cultivationOf(actor).GetRealm(),
		}
	end,
	observe = function(actor: KRF.Actor, onCommitted: (events: { any }?) -> ()): () -> ()
		return cultivationOf(actor).Observe(function(realm: number)
			onCommitted({ { id = "BrokeThrough", payload = { Realm = realm } } })
		end)
	end,
}

return Cultivation
```

When a realm changes, our observer will call `onCommitted` with the `BrokeThrough` event. KRF will read a fresh snapshot and replicate the state change with that event. Returning the disconnect function from `Observe` will let KRF remove the listener during cleanup.

We've set `audience = "All"` so every client will receive this domain. The `U8` schema stores a whole number from 0 to 255, which is enough for our four realm numbers.

## Read the realm on the client

Let's add the realm name to the label we already have. In `src/client/Hud.luau`, add this require beside the others:

```lua
local Realms = require(ReplicatedStorage.Shared.Realms)
```

In `status`, insert this after the line that creates `text`, before the Action checks:

```lua
local cultivation: KRF.DomainView? = view:GetDomain("Cultivation")

if cultivation ~= nil then
	text = `{Realms.NAMES[cultivation:GetState().Realm]} · {text}`
end
```

`GetDomain` returns a DomainView, the client's read-only access to that domain. We'll read its current `Realm` value and use the shared module to look up the name.

## Receive breakthroughs from other characters

The label reads only our own character's state. To receive everyone's breakthrough events, we'll subscribe to the Cultivation domain on every ActorView.

Add this function above `Hud.Start`:

```lua
local function watch(view: KRF.ActorView): ()
	local cultivation: KRF.DomainView? = view:GetDomain("Cultivation")
	local brokeThrough: KRF.Event<any>? = if cultivation ~= nil then cultivation:GetEvent("BrokeThrough") else nil

	if brokeThrough ~= nil then
		brokeThrough:Connect(function(payload: { Realm: number })
			local model: Model? = view:GetModel()
			local name: string = if model ~= nil then model.Name else "A cultivator"

			print(`{name} reached {Realms.NAMES[payload.Realm]}`)
		end)
	end
end
```

At the end of `Hud.Start`, after the existing `RenderStepped` connection, add:

```lua
KRF.ActorViewRegistry.OnActorViewAdded:Connect(watch)

for _, view: KRF.ActorView in KRF.ActorViewRegistry.GetAllActorViews() do
	watch(view)
end
```

The loop will subscribe to characters that already exist. `OnActorViewAdded` will handle characters that appear later, including after a respawn. Each client will print a message when any of those characters breaks through.

## Try it

Press Play and check the label for `Qi Condensation`. After a breakthrough, it should change to `Foundation Establishment`, and the client's Output window should print the same realm name.

Then start a local server with two players from Studio's Test tab. Break through on one character and check both clients' Output windows. Both should receive the event, even though the other character's realm hasn't changed.

## Next

In [Join a sect](./join-a-sect), we'll let players choose a technique and use it alongside Meditate and Breakthrough.
