--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect

local ActorTypes = require(KRF.server.Actor.types)
local ResourceTypes = require(KRF.server.Resource.types)
local SignalTypes = require(KRF.shared.Signal.types)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local SignalModule = require(KRF.shared.Signal.SignalModule)
local OwnedSignals = require(KRF.shared.Signal.OwnedSignals)
local ResourceControllerEvent = require(KRF.server.Resource.utils.ResourceControllerEvent)

type Actor = ActorTypes.Actor
type ResourceChange = ResourceTypes.ResourceChange
type ResourceEventJournal = ResourceControllerEvent.ResourceEventJournal

local function change(actor: Actor, resourceId: string, previous: number, current: number): ResourceChange
	return {
		actor = actor,
		resourceId = resourceId,
		currentOldValue = previous,
		currentNewValue = current,
		minOldValue = 0,
		minNewValue = 0,
		maxOldValue = 100,
		maxNewValue = 100,
	}
end

it("publishes sorted net changes only after the outermost mutation batch closes", function()
	local actor: Actor = ActorEntity.new()
	local signal: SignalTypes.Signal<ResourceChange> = SignalModule.new()
	local ownedSignals: SignalTypes.OwnedSignals = OwnedSignals.new({ signal })
	local journal: ResourceEventJournal = ResourceControllerEvent.new(ownedSignals, signal)
	local changes: { ResourceChange } = {}
	signal:Connect(function(event: ResourceChange)
		table.insert(changes, event)
	end)

	journal:BeginBatch()
	journal:Queue(change(actor, "Mana", 100, 80))
	journal:BeginBatch()
	journal:Queue(change(actor, "Chakra", 100, 90))
	journal:Queue(change(actor, "Mana", 80, 60))
	journal:Queue(change(actor, "Guard", 100, 50))
	journal:Queue(change(actor, "Guard", 50, 100))
	journal:FinishBatch()
	journal:Drain()
	expect(#changes).toBe(0)

	journal:FinishBatch()
	expect(#changes).toBe(0)
	journal:Drain()
	expect(#changes).toBe(2)
	expect(changes[1]).toEqual(change(actor, "Chakra", 100, 90))
	expect(changes[2]).toEqual(change(actor, "Mana", 100, 60))
	journal:Drain()
	expect(#changes).toBe(2)

	journal:Destroy()
	ownedSignals:Destroy()
end)

it("discards pending and batched changes on destruction and ignores later publications", function()
	local actor: Actor = ActorEntity.new()
	local signal: SignalTypes.Signal<ResourceChange> = SignalModule.new()
	local ownedSignals: SignalTypes.OwnedSignals = OwnedSignals.new({ signal })
	local journal: ResourceEventJournal = ResourceControllerEvent.new(ownedSignals, signal)
	local count: number = 0
	signal:Connect(function(_event: ResourceChange)
		count += 1
	end)

	journal:Queue(change(actor, "Mana", 100, 80))
	journal:BeginBatch()
	journal:Queue(change(actor, "Chakra", 100, 90))
	journal:Destroy()
	journal:FinishBatch()
	journal:Queue(change(actor, "Mana", 80, 60))
	journal:Drain()
	journal:Destroy()
	expect(count).toBe(0)

	ownedSignals:Destroy()
end)
