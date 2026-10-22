--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local ResourceTypes = require(KRF.server.Resource.types)
local TagTypes = require(KRF.server.Tags.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Instances = require(KRF.server.Action.utils.ActionControllerInstances)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActionsReplicationTestUtils)

local originalNew = Instances.new
beforeEach(ActionUtils.reset)

afterEach(function()
	Instances.new = originalNew
	ActionUtils.cleanup()
end)

local function seedSequence(sequenceId: number): ()
	Instances.new = function(
		actor: ActorTypes.Actor,
		owned: SignalTypes.OwnedSignals,
		started: SignalTypes.Signal<ActionTypes.ActionLifecycleEvent>,
		ended: SignalTypes.Signal<ActionTypes.ActionLifecycleEvent>,
		interrupted: SignalTypes.Signal<ActionTypes.ActionInterruptedEvent>,
		state: { destroyed: boolean },
		_seed: number?
	): Instances.ActionControllerInstances
		return originalNew(actor, owned, started, ended, interrupted, state, sequenceId)
	end
end

for _, visibility: ActionTypes.ActionVisibility in { "ClientVisible", "ServerOnly" } do
	it("accepts U32 max then rejects exhaustion before costs, Tags and preemption for " .. visibility, function()
		local owner: ActionTypes.ActionDefinition = TestUtils.action("Owner")
		owner.locks = { "Hands" }
		owner.interruptibleBy = { "Incoming" }
		owner.activeTags = { "OwnerA" }

		local incoming: ActionTypes.ActionDefinition = TestUtils.action("Incoming", visibility)
		incoming.locks = { "Hands" }
		incoming.costs = { Mana = 20 }
		incoming.activeTags = { "Incoming" }
		incoming.appliedTags = { "Applied" }
		TestUtils.initialize({ owner, incoming })
		seedSequence(4294967295)

		local actor: ActorTypes.Actor, actions: ActionTypes.ActionController, resources: ResourceTypes.ResourceController, _properties, tags: TagTypes.TagController =
			ActionUtils.registerActor()

		local sequence: number = TestUtils.accept(actions, "Owner")
		expect(sequence).toBe(4294967295)
		local publicEvents: number = 0

		actions.OnActionInterrupted:Connect(function()
			publicEvents += 1
		end)

		actions.OnActionStarted:Connect(function()
			publicEvents += 1
		end)

		local before: number = TestUtils.publication():GetActorSequence(actor)
		local result: ActionTypes.ActionRequestResult = actions:RequestAction("Incoming")
		-- Assert the unchanged authoritative truth even when admission is missing.
		expect(resources:GetCurrent("Mana")).toBe(100)
		expect(tags:HasTag("OwnerA")).toBe(true)
		expect(tags:HasTag("Incoming")).toBe(false)
		expect(tags:HasTag("Applied")).toBe(false)
		expect(publicEvents).toBe(0)
		expect(TestUtils.publication():GetActorSequence(actor)).toBe(before)
		expect(result).toEqual({ accepted = false, reason = "ActionSequenceIdExhausted" })
		expect(actions:EndAction(sequence)).toBe(true)
		expect(actions:RequestAction("Incoming")).toEqual({ accepted = false, reason = "ActionSequenceIdExhausted" })
	end)
end

it("starts at one and never reuses a terminal identity in the shared visible/private namespace", function()
	TestUtils.initialize({ TestUtils.action("Visible"), TestUtils.action("Private", "ServerOnly") })
	local _actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
	expect(TestUtils.accept(actions, "Visible")).toBe(1)
	expect(actions:EndAction(1)).toBe(true)
	expect(TestUtils.accept(actions, "Private")).toBe(2)
	expect(actions:InterruptAction(2, "SecretReason")).toBe(true)
	expect(TestUtils.accept(actions, "Visible")).toBe(3)
end)

it("rejects the 257th visible instance without spending, applying Tags or issuing lifecycle callbacks", function()
	local incoming: ActionTypes.ActionDefinition = TestUtils.action("Incoming")
	incoming.costs = { Mana = 20 }
	incoming.activeTags = { "Incoming" }
	incoming.appliedTags = { "Applied" }
	TestUtils.initialize({ TestUtils.action("Visible"), incoming })

	local actor: ActorTypes.Actor, actions: ActionTypes.ActionController, resources: ResourceTypes.ResourceController, _properties, tags: TagTypes.TagController =
		ActionUtils.registerActor()

	for sequence: number = 1, 256 do
		expect(TestUtils.accept(actions, "Visible")).toBe(sequence)
	end

	local started: number = 0

	actions.OnActionStarted:Connect(function()
		started += 1
	end)

	local before: number = TestUtils.publication():GetActorSequence(actor)
	local result: ActionTypes.ActionRequestResult = actions:RequestAction("Incoming")
	expect(resources:GetCurrent("Mana")).toBe(100)
	expect(tags:HasTag("Incoming")).toBe(false)
	expect(tags:HasTag("Applied")).toBe(false)
	expect(started).toBe(0)
	expect(TestUtils.publication():GetActorSequence(actor)).toBe(before)
	expect(result).toEqual({ accepted = false, reason = "ActionVisibleInstanceLimitReached" })
	expect(actions:EndAction(256)).toBe(true)
	-- A rejected request must not reserve sequence 257.
	expect(TestUtils.accept(actions, "Incoming")).toBe(257)
end)

for _, ownerVisibility: ActionTypes.ActionVisibility in { "ClientVisible", "ServerOnly" } do
	it("accounts for planned " .. ownerVisibility .. " owner preemption before visible capacity admission", function()
		local owner: ActionTypes.ActionDefinition = TestUtils.action("Owner", ownerVisibility)
		owner.locks = { "Hands" }
		owner.activeTags = { "OwnerA" }
		owner.interruptibleBy = { "Incoming" }

		local incoming: ActionTypes.ActionDefinition = TestUtils.action("Incoming")
		incoming.locks = { "Hands" }
		incoming.activeTags = { "Incoming" }
		incoming.costs = { Mana = 20 }
		TestUtils.initialize({ TestUtils.action("Visible"), owner, incoming })

		local actor: ActorTypes.Actor, actions: ActionTypes.ActionController, resources: ResourceTypes.ResourceController, _properties, tags: TagTypes.TagController =
			ActionUtils.registerActor()

		TestUtils.accept(actions, "Owner")

		for _ = 1, if ownerVisibility == "ClientVisible" then 255 else 256 do
			TestUtils.accept(actions, "Visible")
		end

		local result: ActionTypes.ActionRequestResult = actions:RequestAction("Incoming")

		if ownerVisibility == "ServerOnly" then
			expect(resources:GetCurrent("Mana")).toBe(100)
			expect(tags:HasTag("OwnerA")).toBe(true)
			expect(tags:HasTag("Incoming")).toBe(false)
			expect(result).toEqual({ accepted = false, reason = "ActionVisibleInstanceLimitReached" })
		else
			expect(result.accepted).toBe(true)
			expect(resources:GetCurrent("Mana")).toBe(80)
			expect(tags:HasTag("OwnerA")).toBe(false)
			expect(tags:HasTag("Incoming")).toBe(true)
			local count: number = 0

			for _ in TestUtils.state(actor) do
				count += 1
			end

			expect(count).toBe(256)
		end
	end)
end

it("excludes ServerOnly activations from visible capacity while preserving global sequence identity", function()
	TestUtils.initialize({ TestUtils.action("Visible"), TestUtils.action("Private", "ServerOnly") })
	local _actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()

	for _ = 1, 256 do
		TestUtils.accept(actions, "Private")
	end

	for sequence: number = 257, 512 do
		expect(TestUtils.accept(actions, "Visible")).toBe(sequence)
	end

	expect(TestUtils.accept(actions, "Private")).toBe(513)
	expect(actions:RequestAction("Visible")).toEqual({ accepted = false, reason = "ActionVisibleInstanceLimitReached" })
end)
