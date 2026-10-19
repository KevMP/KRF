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
local GoodSignal: any = require(KRF.shared.Signal.GoodSignal)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActionsReplicationTestUtils)

local originalFire: any = GoodSignal.Fire
local originalConnect: any = GoodSignal.Connect
beforeEach(ActionUtils.reset)

afterEach(function()
	GoodSignal.Fire = originalFire
	GoodSignal.Connect = originalConnect
	ActionUtils.cleanup()
end)

it("reports committed active truth synchronously before actual lifecycle Fire and authored hooks", function()
	local order: { string } = {}

	local definition: ActionTypes.ActionDefinition = TestUtils.action("Visible")

	definition.onStart = function()
		table.insert(order, "onStart")
	end

	definition.onEnd = function()
		table.insert(order, "onEnd")
	end

	TestUtils.initialize({ definition })
	local _actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
	local internal: TestUtils.InternalController = TestUtils.internal(actions)
	local batches: { { TestUtils.Mutation } } = {}
	local states: { { TestUtils.Identity } } = {}
	local startedSignal: any = nil

	GoodSignal.Connect = function(self: any, callback: any): any
		startedSignal = self

		return originalConnect(self, callback)
	end

	actions.OnActionStarted:Connect(function() end)
	GoodSignal.Connect = originalConnect

	GoodSignal.Fire = function(self: any, ...: any)
		if self == startedSignal then
			table.insert(order, "StartedFire")
		end

		originalFire(self, ...)
	end

	local disconnect: () -> () = internal:_observeMutations(function(mutations: { TestUtils.Mutation })
		table.insert(order, mutations[1].kind)
		table.insert(batches, mutations)
		table.insert(states, internal:_getActiveReplicationState())
	end)

	local sequence: number = TestUtils.accept(actions, "Visible", { secret = function() end })
	expect(actions:EndAction(sequence)).toBe(true)
	expect(order).toEqual({ "Started", "StartedFire", "onStart", "Ended", "onEnd" })

	expect(batches).toEqual({
		{ { kind = "Started", actionId = "Visible", sequenceId = 1 } },
		{ { kind = "Ended", actionId = "Visible", sequenceId = 1 } },
	})

	expect(states).toEqual({ { { actionId = "Visible", sequenceId = 1 } }, {} })
	disconnect()
	disconnect()
	TestUtils.accept(actions, "Visible")
	expect(#batches).toBe(2)
end)

it(
	"reports one owner-ordered transaction batch after every conflicting owner is inactive and incoming is active",
	function()
		local first: ActionTypes.ActionDefinition = TestUtils.action("A")
		first.locks = { "Hands" }
		first.interruptibleBy = { "Incoming" }

		local second: ActionTypes.ActionDefinition = TestUtils.action("B", "ServerOnly")
		second.locks = { "Feet" }
		second.interruptibleBy = { "Incoming" }

		local incoming: ActionTypes.ActionDefinition = TestUtils.action("Incoming")
		incoming.locks = { "Feet", "Hands" }
		TestUtils.initialize({ first, second, incoming })
		local _actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
		TestUtils.accept(actions, "A")
		TestUtils.accept(actions, "B")
		local internal: TestUtils.InternalController = TestUtils.internal(actions)
		local batches: { { TestUtils.Mutation } } = {}
		local states: { { TestUtils.Identity } } = {}

		internal:_observeMutations(function(mutations: { TestUtils.Mutation })
			table.insert(batches, mutations)
			table.insert(states, internal:_getActiveReplicationState())
		end)

		TestUtils.accept(actions, "Incoming")

		expect(batches).toEqual({
			{
				{ kind = "Interrupted", actionId = "A", sequenceId = 1 },
				{ kind = "Interrupted", actionId = "B", sequenceId = 2 },
				{ kind = "Started", actionId = "Incoming", sequenceId = 3 },
			},
		})

		expect(states).toEqual({ { { actionId = "Incoming", sequenceId = 3 } } })
	end
)

it("snapshots only current identity in ascending sequence order without granting a public introspection API", function()
	TestUtils.initialize({ TestUtils.action("Visible"), TestUtils.action("Private", "ServerOnly") })
	local _actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
	TestUtils.accept(actions, "Visible", { private = "NeverSerialize" })
	TestUtils.accept(actions, "Private")
	TestUtils.accept(actions, "Visible")
	expect(actions:EndAction(2)).toBe(true)
	local internal: TestUtils.InternalController = TestUtils.internal(actions)
	local retained: { TestUtils.Identity } = internal:_getActiveReplicationState()
	expect(retained).toEqual({ { actionId = "Visible", sequenceId = 1 }, { actionId = "Visible", sequenceId = 3 } })
	expect(actions:EndAction(1)).toBe(true)
	expect(retained).toEqual({ { actionId = "Visible", sequenceId = 1 }, { actionId = "Visible", sequenceId = 3 } })
	expect(internal:_getActiveReplicationState()).toEqual({ { actionId = "Visible", sequenceId = 3 } })
	expect((actions :: any).GetActiveActions).toBeNil()
end)

for _, terminal: string in { "Ended", "Interrupted", "Destroy" } do
	it("reports " .. terminal .. " once and retains the server-only interruption reason on server callbacks", function()
		TestUtils.initialize({ TestUtils.action("Visible") })
		local _actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
		TestUtils.accept(actions, "Visible")
		local internal: TestUtils.InternalController = TestUtils.internal(actions)
		local mutations: { { TestUtils.Mutation } } = {}
		local reasons: { string } = {}

		actions.OnActionInterrupted:Connect(function(event: ActionTypes.ActionInterruptedEvent)
			table.insert(reasons, event.reason)
		end)

		internal:_observeMutations(function(batch: { TestUtils.Mutation })
			table.insert(mutations, batch)
		end)

		if terminal == "Ended" then
			expect(actions:EndAction(1)).toBe(true)
			expect(actions:EndAction(1)).toBe(false)
		elseif terminal == "Interrupted" then
			expect(actions:InterruptAction(1, "Private.ServerReason")).toBe(true)
			expect(actions:InterruptAction(1, "Private.ServerReason")).toBe(false)
		else
			actions:Destroy()
			actions:Destroy()
		end

		expect(mutations).toEqual({
			{ { kind = if terminal == "Ended" then "Ended" else "Interrupted", actionId = "Visible", sequenceId = 1 } },
		})

		expect(reasons).toEqual(
			if terminal == "Ended"
				then {}
				else { if terminal == "Destroy" then "ActionControllerDestroyed" else "Private.ServerReason" }
		)

		expect(internal:_getActiveReplicationState()).toEqual({})
	end)
end
