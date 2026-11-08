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
local PropertyTypes = require(KRF.server.Property.types)
local TagTypes = require(KRF.server.Tags.types)
local TestUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)

type ActionDefinition = ActionTypes.ActionDefinition
type InternalActionController = ActionTypes.InternalActionController

beforeEach(TestUtils.reset)
afterEach(TestUtils.cleanup)

local mana: ResourceTypes.ResourceDefinition = {
	id = "Mana",
	visibility = "ServerOnly",
	autoAssign = true,
	min = { propertyName = "MinMana", defaultBaseValue = 0 },
	max = { propertyName = "MaxMana", defaultBaseValue = 100 },
	initialValue = 100,
}

local channel: TagTypes.TagDefinition = { id = "Channeling", visibility = "ServerOnly", duplicateBehavior = "Ignore" }

type Fixture = {
	actor: ActorTypes.Actor,
	actions: InternalActionController,
	resources: ResourceTypes.ResourceController,
	tags: TagTypes.TagController,
	order: { string },
}

-- Incoming preempts Stance through a shared lock, spends Mana and applies Channeling,
-- so every guarded side effect is observable on the real controllers.
local function setup(onCanStart: ActionTypes.OnCanStart?): Fixture
	local order: { string } = {}

	local stance: ActionDefinition = {
		id = "Stance",
		visibility = "ServerOnly",
		autoGrant = true,
		locks = { "Hands" },
		interruptibleBy = { "Incoming" },
		canBeInterruptedBy = function(): boolean
			table.insert(order, "canBeInterruptedBy")

			return true
		end,
		onInterrupt = function(): ()
			table.insert(order, "StanceInterrupted")
		end,
	}

	local incoming: ActionDefinition = {
		id = "Incoming",
		visibility = "ServerOnly",
		autoGrant = true,
		locks = { "Hands" },
		costs = { Mana = 30 },
		activeTags = { "Channeling" },
		onCanStart = function(context: ActionTypes.ActionStartContext): (boolean, string?)
			table.insert(order, "onCanStart")

			if onCanStart ~= nil then
				return onCanStart(context)
			end

			return true, nil
		end,
		onStart = function(): ()
			table.insert(order, "onStart")
		end,
	}

	TestUtils.initialize({ stance, incoming }, { mana }, { channel })

	local actor: ActorTypes.Actor, actions: ActionTypes.ActionController, resources: ResourceTypes.ResourceController, _properties: PropertyTypes.PropertyController, tags: TagTypes.TagController =
		TestUtils.registerActor()

	local stanceResult: ActionTypes.ActionRequestResult = actions:RequestAction("Stance")
	expect(stanceResult.accepted).toBe(true)
	table.clear(order)

	return {
		actor = actor,
		actions = actions :: InternalActionController,
		resources = resources,
		tags = tags,
		order = order,
	}
end

local function expectNoEffects(fixture: Fixture): ()
	expect(fixture.resources:GetCurrent("Mana")).toBe(100)
	expect(fixture.tags:HasTag("Channeling")).toBe(false)
	expect(table.find(fixture.order, "onStart")).toBeNil()
	expect(table.find(fixture.order, "StanceInterrupted")).toBeNil()

	local active: { ActionTypes.ActionReplicationIdentity } = fixture.actions:_getActiveReplicationState()
	expect(#active).toBe(1)
	expect(active[1].actionId).toBe("Stance")
end

it("starts normally and returns the real sequence id when the guard allows", function()
	local fixture: Fixture = setup()
	local calls: number = 0

	local result: ActionTypes.ActionRequestResult = fixture.actions:_requestGuardedAction(
		"Incoming",
		nil,
		function(): string?
			calls += 1

			return nil
		end
	)

	expect(result.accepted).toBe(true)
	expect(calls).toBe(1)
	expect(fixture.resources:GetCurrent("Mana")).toBe(70)
	expect(fixture.tags:HasTag("Channeling")).toBe(true)
end)

it("rejects before costs, preemption, Tags and instance creation when the guard denies", function()
	local fixture: Fixture = setup()

	local result: ActionTypes.ActionRequestResult = fixture.actions:_requestGuardedAction(
		"Incoming",
		nil,
		function(): string?
			return "ActorControlRevoked"
		end
	)

	expect(result).toEqual({ accepted = false, reason = "ActorControlRevoked" })
	expect(fixture.resources:GetCurrent("Mana")).toBe(100)
	expect(fixture.tags:HasTag("Channeling")).toBe(false)
	expect(table.find(fixture.order, "onStart")).toBeNil()
	expect(table.find(fixture.order, "StanceInterrupted")).toBeNil()
end)

it("evaluates the guard after onCanStart and interruption decisions", function()
	local fixture: Fixture = setup()

	fixture.actions:_requestGuardedAction("Incoming", nil, function(): string?
		table.insert(fixture.order, "guard")

		return nil
	end)

	expect(fixture.order[1]).toBe("onCanStart")
	expect(fixture.order[2]).toBe("canBeInterruptedBy")
	expect(fixture.order[3]).toBe("guard")
end)

it("rejects without effects when onCanStart revokes network control observed by the guard", function()
	local owned: boolean = true

	local fixture: Fixture = setup(function(): (boolean, string?)
		owned = false

		return true, nil
	end)

	local result: ActionTypes.ActionRequestResult = fixture.actions:_requestGuardedAction(
		"Incoming",
		nil,
		function(): string?
			return if owned then nil else "ActorNotOwned"
		end
	)

	expect(result).toEqual({ accepted = false, reason = "ActorNotOwned" })
	expectNoEffects(fixture)
end)

it("contains a throwing guard as a pre-effect rejection", function()
	local fixture: Fixture = setup()

	local result: ActionTypes.ActionRequestResult = fixture.actions:_requestGuardedAction(
		"Incoming",
		nil,
		function(): string?
			error("GuardExploded")
		end
	)

	expect(result).toEqual({ accepted = false, reason = "ActionStartGuardFailed" })
	expectNoEffects(fixture)
end)

it("contains a yielding guard as a pre-effect rejection", function()
	local fixture: Fixture = setup()

	local result: ActionTypes.ActionRequestResult = fixture.actions:_requestGuardedAction(
		"Incoming",
		nil,
		function(): string?
			task.wait()

			return nil
		end
	)

	expect(result).toEqual({ accepted = false, reason = "ActionStartGuardYielded" })
	expectNoEffects(fixture)
end)

it("keeps earlier ActionController rejections ahead of the guard", function()
	local fixture: Fixture = setup(function(): (boolean, string?)
		return false, "FireballNotEquipped"
	end)

	local calls: number = 0

	local result: ActionTypes.ActionRequestResult = fixture.actions:_requestGuardedAction(
		"Incoming",
		nil,
		function(): string?
			calls += 1

			return nil
		end
	)

	expect(result).toEqual({ accepted = false, reason = "FireballNotEquipped" })
	expect(calls).toBe(0)
end)
