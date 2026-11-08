--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local ActionRequestTypes = require(KRF.shared.ActionRequest.types)
local TestUtils = require(script.Parent.Parent.Utils.ActionRequest.ActionRequestServerTestUtils)

local fixture: TestUtils.Fixture? = nil

afterEach(function()
	TestUtils.destroy(fixture)
	fixture = nil
end)

local schemas: ActionRequestTypes.ActionRequestSchemas = {
	["Movement.Sprint"] = {
		stop = {},
		allowInputInterrupt = true,
		requiresClientRelease = true,
		onDisconnect = "Interrupt",
	},
	["Aura.Persistent"] = { stop = {}, onDisconnect = "Keep" },
}

type Hooks = {
	onCanStart: (() -> ())?,
	onStart: (() -> ())?,
}

type Trace = { stops: number, interrupts: { string }, started: number }

local function setup(hooks: Hooks?): (TestUtils.Fixture, Trace)
	local trace: Trace = { stops = 0, interrupts = {}, started = 0 }
	local definitions: { ActionTypes.ActionDefinition } = {}

	for _, actionId: string in { "Movement.Sprint", "Aura.Persistent", "Server.Owned" } do
		table.insert(definitions, {
			id = actionId,
			visibility = "ClientVisible" :: ActionTypes.ActionVisibility,
			autoGrant = true,
			onCanStart = function(): (boolean, string?)
				if hooks ~= nil and hooks.onCanStart ~= nil then
					hooks.onCanStart()
				end

				return true, nil
			end,
			onStart = function(): ()
				trace.started += 1

				if hooks ~= nil and hooks.onStart ~= nil then
					hooks.onStart()
				end
			end,
			onStopRequested = function(): ()
				trace.stops += 1
			end,
			onInterrupt = function(context: ActionTypes.ActionExecutionContext): ()
				table.insert(trace.interrupts, context.actionId)
			end,
		})
	end

	local created: TestUtils.Fixture = TestUtils.new(definitions, schemas)
	fixture = created

	return created, trace
end

local function activeIds(created: TestUtils.Fixture): { string }
	local ids: { string } = {}

	for _, identity: ActionTypes.ActionReplicationIdentity in TestUtils.active(created) do
		table.insert(ids, identity.actionId)
	end

	table.sort(ids)

	return ids
end

it("interrupts a live Interrupt-policy Action and keeps a Keep-policy Action on disconnect", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	TestUtils.start(created, 1, "Movement.Sprint")
	TestUtils.start(created, 2, "Aura.Persistent")
	TestUtils.expectAccepted(created, 1)
	TestUtils.expectAccepted(created, 2)
	TestUtils.close(created)
	expect(trace.interrupts).toEqual({ "Movement.Sprint" })
	expect(activeIds(created)).toEqual({ "Aura.Persistent" })
	expect(created.runtime:_GetReceiptCountForTests()).toBe(0)
end)

it("never interrupts a server-started Action of the same id on disconnect", function()
	local created: TestUtils.Fixture, trace: Trace = setup()

	local result: ActionTypes.ActionRequestResult = TestUtils.controller(created, created.commands.actor)
		:RequestAction("Movement.Sprint")

	expect(result.accepted).toBe(true)
	TestUtils.start(created, 1, "Movement.Sprint")
	TestUtils.expectAccepted(created, 1)
	TestUtils.close(created)
	expect(trace.interrupts).toEqual({ "Movement.Sprint" })
	expect(activeIds(created)).toEqual({ "Movement.Sprint" })
end)

it("leaves another Player's receipts untouched when one connection closes", function()
	local created: TestUtils.Fixture = setup()
	local other: Player = created.commands.other
	local mount: ActorTypes.Actor = TestUtils.actor(created, other)
	TestUtils.start(created, 1, "Movement.Sprint")
	TestUtils.start(created, 1, "Movement.Sprint", nil, { player = other, actor = mount })
	TestUtils.expectAccepted(created, 1)
	TestUtils.expectAccepted(created, 1, other)
	TestUtils.close(created)
	expect(#TestUtils.active(created, mount)).toBe(1)
	expect(created.runtime:_GetReceiptCountForTests()).toBe(1)
end)

it("prevents a reconnected generation from reusing an old numeric receipt", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	TestUtils.start(created, 1, "Aura.Persistent")
	TestUtils.expectAccepted(created, 1)
	TestUtils.close(created)
	TestUtils.reconnect(created)
	TestUtils.stop(created, 1, 1, "Aura.Persistent")
	TestUtils.expectRejected(created, 1, "ActionReceiptUnknown")
	expect(trace.stops).toBe(0)
	expect(activeIds(created)).toEqual({ "Aura.Persistent" })
end)

it("rejects without effects when the connection closes during onCanStart", function()
	local closeNow: (() -> ())? = nil

	local created: TestUtils.Fixture, trace: Trace = setup({
		onCanStart = function(): ()
			if closeNow ~= nil then
				closeNow()
			end
		end,
	})

	closeNow = function(): ()
		closeNow = nil
		TestUtils.close(created)
	end

	TestUtils.start(created, 1, "Movement.Sprint")
	expect(trace.started).toBe(0)
	expect(TestUtils.active(created)).toEqual({})
	expect(created.runtime:_GetReceiptCountForTests()).toBe(0)
end)

it("applies Interrupt to the exact accepted sequence when the connection closes during onStart", function()
	local closeNow: (() -> ())? = nil

	local created: TestUtils.Fixture, trace: Trace = setup({
		onStart = function(): ()
			if closeNow ~= nil then
				closeNow()
			end
		end,
	})

	closeNow = function(): ()
		closeNow = nil
		TestUtils.close(created)
	end

	TestUtils.start(created, 1, "Movement.Sprint")
	expect(trace.started).toBe(1)
	expect(trace.interrupts).toEqual({ "Movement.Sprint" })
	expect(TestUtils.active(created)).toEqual({})
	expect(created.runtime:_GetReceiptCountForTests()).toBe(0)
end)

it("keeps a Keep-policy Action accepted while the connection closes during onStart", function()
	local closeNow: (() -> ())? = nil

	local created: TestUtils.Fixture, trace: Trace = setup({
		onStart = function(): ()
			if closeNow ~= nil then
				closeNow()
			end
		end,
	})

	closeNow = function(): ()
		closeNow = nil
		TestUtils.close(created)
	end

	TestUtils.start(created, 1, "Aura.Persistent")
	expect(trace.started).toBe(1)
	expect(trace.interrupts).toEqual({})
	expect(activeIds(created)).toEqual({ "Aura.Persistent" })
	expect(created.runtime:_GetReceiptCountForTests()).toBe(0)
end)

it("releases every receipt without touching Actions when the runtime is destroyed", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	TestUtils.start(created, 1, "Movement.Sprint")
	TestUtils.expectAccepted(created, 1)
	created.runtime:Destroy()
	created.runtime:Destroy()
	expect(created.runtime:_GetReceiptCountForTests()).toBe(0)
	expect(trace.interrupts).toEqual({})
	expect(activeIds(created)).toEqual({ "Movement.Sprint" })
end)
