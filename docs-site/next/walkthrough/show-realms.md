---
title: Show realms to everyone
sidebar_label: 7. Show realms
sidebar_position: 8
description: Replicate each cultivator's realm with a replication domain and announce breakthroughs to every player.
---

# Show realms to everyone

A cultivator's realm lives in the server's Cultivation Controller, and clients can't see it. In this chapter every player sees their own realm in the HUD, and everyone is told when someone breaks through.

## Replication domains

KRF replicates its own state, such as Resources and Tags, automatically. To replicate state you own, you declare a replication domain. It describes what to send and how to read it from the Actor, and KRF handles sending it, keeping late joiners up to date and recovering after reconnects.

```bash
npm run createDomain -- --name Cultivation --audience All --state-field Realm:U8 --event "BrokeThrough(Realm:U8)" --observe
```

A domain separates two things. Its state is what's true now, here the realm, and KRF can always rebuild it for a client that just joined. Its events are things that happened, such as a breakthrough. They're delivered to clients who are connected when they happen and never replayed.

## Tell the domain when the realm changes

The domain needs to know when to read the realm again. Give the Cultivation Controller an `Observe` function in `src/server/Controllers/Cultivation.luau`:

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

`Advance` now notifies its listeners immediately after changing the realm, before it sets `MaxQi`. That order matters: setting a Property runs other code through Property events, and KRF needs the domain told about the new realm before any of that code can run.

Fill in the generated domain, `src/server/ReplicationDomains/Cultivation.luau`:

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

`snapshot` returns the full current state whenever KRF needs it. `observe` connects to the Controller. Each time the realm changes it calls `onCommitted` with the breakthrough event, and KRF takes a new snapshot and sends both. `observe` returns the Controller's disconnect function so KRF can clean up when the Actor goes away. `audience = "All"` sends the domain to every client; `"Owner"` would send it only to the player whose character the Actor is.

## Show realms and breakthroughs

On the client, every ActorView now has a Cultivation domain. Update `src/client/Hud.luau`:

```lua title="src/client/Hud.luau"
--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local KRF = require(ReplicatedStorage.Packages.KRF)
local LocalCharacter = require(script.Parent.LocalCharacter)
local Realms = require(ReplicatedStorage.Shared.Realms)

local Hud = {}

local announcement: TextLabel? = nil

local function meter(resources: KRF.ResourcesView, resourceId: string): string
	return `{resourceId} {math.floor(resources:GetCurrent(resourceId) or 0)}/{resources:GetMax(resourceId) or 0}`
end

local function status(view: KRF.ActorView): string
	local resources: KRF.ResourcesView = view:GetResources()
	local text: string = `{meter(resources, "Qi")} · {meter(resources, "Vitality")}`
	local cultivation: KRF.DomainView? = view:GetDomain("Cultivation")

	if cultivation ~= nil then
		text = `{Realms.NAMES[cultivation:GetState().Realm]} · {text}`
	end

	if view:GetTags():HasTag("KnockedOut") then
		text ..= " · Knocked out"
	elseif view:GetTags():HasTag("BreakingThrough") then
		text ..= " · Breaking through"
	elseif view:GetActions():IsActionActive("Meditate") then
		text ..= " · Meditating"
	end

	return text
end

function Hud.Announce(text: string): ()
	local notice: TextLabel? = announcement

	if notice == nil then
		return
	end

	notice.Text = text
	notice.Visible = true

	task.delay(3, function()
		if notice.Text == text then
			notice.Visible = false
		end
	end)
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

	local notice: TextLabel = label:Clone()
	notice.Name = "Announcement"
	notice.Position = UDim2.new(0, 16, 1, -104)
	notice.Visible = false
	notice.Parent = gui
	announcement = notice

	gui.Parent = player:WaitForChild("PlayerGui")

	RunService.RenderStepped:Connect(function()
		local view: KRF.ActorView? = LocalCharacter.Get()
		local text: string = if view ~= nil then status(view) else ""

		if label.Text ~= text then
			label.Text = text
		end
	end)

	local function watch(view: KRF.ActorView): ()
		local cultivation: KRF.DomainView? = view:GetDomain("Cultivation")
		local brokeThrough: KRF.Event<any>? = if cultivation ~= nil then cultivation:GetEvent("BrokeThrough") else nil

		if brokeThrough ~= nil then
			brokeThrough:Connect(function(payload: { Realm: number })
				local model: Model? = view:GetModel()
				local name: string = if model ~= nil then model.Name else "A cultivator"

				Hud.Announce(`{name} reached {Realms.NAMES[payload.Realm]}`)
			end)
		end
	end

	KRF.ActorViewRegistry.OnActorViewAdded:Connect(watch)

	for _, view: KRF.ActorView in KRF.ActorViewRegistry.GetAllActorViews() do
		watch(view)
	end
end

return Hud
```

`status` reads the realm from the domain's current state. The announcement label shows a message for three seconds through `Hud.Announce`, which chapter 8 reuses.

`watch` subscribes to the `BrokeThrough` event on one ActorView. The HUD calls it for every view that already exists and for every view added later, so players hear about every cultivator's breakthrough, including their own.

## Checkpoint

Press Play. The HUD now starts with `Qi Condensation`. Break through and it changes to `Foundation Establishment`, and the announcement label reports it. In a two-player test, the other player sees the same announcement.

## Next

[Join a sect](./join-a-sect) lets players choose a path and learn its technique.
