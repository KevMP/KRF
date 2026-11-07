--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ActionRequestTypes = require(KRF.shared.ActionRequest.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local TestUtils = require(script.Parent.Parent.Utils.ActionRequest.ActionRequestServerTestUtils)

local fixture: TestUtils.Fixture? = nil

afterEach(function()
	TestUtils.destroy(fixture)
	fixture = nil
end)

local schemas: ActionRequestTypes.ActionRequestSchemas = {
	["Technique.Charge"] = {
		stop = { parameters = Schema.Struct({ charge = Schema.U16 }) },
		allowInputInterrupt = true,
		onDisconnect = "Interrupt",
	},
	["Movement.Sprint"] = {
		stop = {},
		allowInputInterrupt = true,
		requiresClientRelease = true,
		onDisconnect = "Interrupt",
	},
	["Stance.Guard"] = { stop = {} },
	["Combat.Fireball"] = {},
}

type Trace = { stops: { any }, interrupts: { string }, ended: { string } }

local function setup(): (TestUtils.Fixture, Trace)
	local trace: Trace = { stops = {}, interrupts = {}, ended = {} }
	local definitions: { ActionTypes.ActionDefinition } = {}

	for _, actionId: string in { "Technique.Charge", "Movement.Sprint", "Stance.Guard", "Combat.Fireball" } do
		table.insert(definitions, {
			id = actionId,
			visibility = "ClientVisible" :: ActionTypes.ActionVisibility,
			autoGrant = true,
			-- Gameplay owns semantic handling of untrusted but structurally valid values.
			onStopRequested = function(
				_context: ActionTypes.ActionExecutionContext,
				request: ActionTypes.ActionStopRequest
			)
				table.insert(trace.stops, request.parameters or false)
			end,
			onInterrupt = function(context: ActionTypes.ActionExecutionContext): ()
				table.insert(trace.interrupts, context.actionId)
			end,
			onEnd = function(context: ActionTypes.ActionExecutionContext): ()
				table.insert(trace.ended, context.actionId)
			end,
		})
	end

	local created: TestUtils.Fixture = TestUtils.new(definitions, schemas)
	fixture = created

	return created, trace
end

local function started(created: TestUtils.Fixture, requestId: number, actionId: string): number
	TestUtils.start(created, requestId, actionId)
	local result: any = TestUtils.expectAccepted(created, requestId)

	return result.sequenceId
end

it("delivers a typed Stop for the original receipt once without ending the Action", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	local sequenceId: number = started(created, 1, "Technique.Charge")
	TestUtils.stop(created, 2, 1, "Technique.Charge", { charge = 40 })
	TestUtils.expectAccepted(created, 2)
	expect(trace.stops).toEqual({ { charge = 40 } })
	expect(TestUtils.active(created)).toEqual({ { actionId = "Technique.Charge", sequenceId = sequenceId } })
end)

it("delivers structurally valid but gameplay-invalid Stop values to the Action unchanged", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	started(created, 1, "Technique.Charge")
	TestUtils.stop(created, 2, 1, "Technique.Charge", { charge = 65535 })
	TestUtils.expectAccepted(created, 2)
	expect(trace.stops).toEqual({ { charge = 65535 } })
end)

it("delivers a parameterless Stop with no parameters", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	started(created, 1, "Movement.Sprint")
	TestUtils.stop(created, 2, 1, "Movement.Sprint")
	TestUtils.expectAccepted(created, 2)
	expect(trace.stops).toEqual({ false })
end)

it("refuses a duplicate Stop so the hook runs at most once", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	started(created, 1, "Technique.Charge")
	TestUtils.stop(created, 2, 1, "Technique.Charge", { charge = 1 })
	TestUtils.stop(created, 3, 1, "Technique.Charge", { charge = 2 })
	TestUtils.expectAccepted(created, 2)
	TestUtils.expectRejected(created, 3, "ActionStopAlreadyDelivered")
	expect(trace.stops).toEqual({ { charge = 1 } })
end)

it("never invokes the hook for malformed Stop bytes and still accepts a later valid Stop", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	started(created, 1, "Technique.Charge")
	TestUtils.stop(created, 2, 1, "Technique.Charge", nil, { payload = "\1" })
	TestUtils.expectRejected(created, 2, "ActionPayloadMalformed")
	expect(trace.stops).toEqual({})
	TestUtils.stop(created, 3, 1, "Technique.Charge", { charge = 9 })
	TestUtils.expectAccepted(created, 3)
	expect(trace.stops).toEqual({ { charge = 9 } })
end)

it("refuses Stop for an Action that declares no Stop path", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	started(created, 1, "Combat.Fireball")
	TestUtils.stop(created, 2, 1, "Combat.Fireball")
	TestUtils.expectRejected(created, 2, "ActionStopUnavailable")
	expect(trace.stops).toEqual({})
end)

it("refuses a guessed receipt id without touching any Action", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	started(created, 1, "Technique.Charge")
	TestUtils.stop(created, 2, 99, "Technique.Charge", { charge = 1 })
	TestUtils.interrupt(created, 3, 98, "FocusLost")
	TestUtils.expectRejected(created, 2, "ActionReceiptUnknown")
	TestUtils.expectRejected(created, 3, "ActionReceiptUnknown")
	expect(trace.stops).toEqual({})
	expect(trace.interrupts).toEqual({})
end)

it("refuses another Player's follow-ups that reuse the same numeric receipt id", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	started(created, 1, "Technique.Charge")
	local other: Player = created.commands.other
	TestUtils.stop(created, 1, 1, "Technique.Charge", { charge = 3 }, { player = other })
	TestUtils.interrupt(created, 2, 1, "FocusLost", other)
	TestUtils.expectRejected(created, 1, "ActionReceiptUnknown", other)
	TestUtils.expectRejected(created, 2, "ActionReceiptUnknown", other)
	expect(trace.stops).toEqual({})
	expect(#TestUtils.active(created)).toBe(1)
end)

it("refuses follow-ups after the original Action reached a terminal state", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	local sequenceId: number = started(created, 1, "Stance.Guard")
	expect({ TestUtils.controller(created, created.commands.actor):EndAction(sequenceId) }).toEqual({ true })
	TestUtils.stop(created, 2, 1, "Stance.Guard")
	TestUtils.expectRejected(created, 2, "ActionReceiptUnknown")
	expect(trace.stops).toEqual({})
	expect(created.runtime:_GetReceiptCountForTests()).toBe(0)
end)

it("targets the original receipt after the Player switches control to another Actor", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	started(created, 1, "Technique.Charge")
	local mount: ActorTypes.Actor = TestUtils.actor(created, nil)
	TestUtils.associate(created, created.commands.actor, nil)
	TestUtils.associate(created, mount, created.commands.player)
	TestUtils.stop(created, 2, 1, "Technique.Charge", { charge = 5 })
	TestUtils.expectAccepted(created, 2)
	expect(trace.stops).toEqual({ { charge = 5 } })
	expect(TestUtils.active(created, mount)).toEqual({})
end)

it("interrupts exactly the original live sequence without calling the Stop hook", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	started(created, 1, "Movement.Sprint")
	local survivor: number = started(created, 2, "Movement.Sprint")
	TestUtils.interrupt(created, 3, 1, "ActorSwitched")
	TestUtils.expectAccepted(created, 3)
	expect(trace.interrupts).toEqual({ "Movement.Sprint" })
	expect(trace.stops).toEqual({})
	expect(TestUtils.active(created)).toEqual({ { actionId = "Movement.Sprint", sequenceId = survivor } })
end)

it("lets a permitted Interrupt terminate an Action that already received its Stop", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	started(created, 1, "Movement.Sprint")
	TestUtils.stop(created, 2, 1, "Movement.Sprint")
	TestUtils.interrupt(created, 3, 1, "StopPreparationFailed")
	TestUtils.expectAccepted(created, 2)
	TestUtils.expectAccepted(created, 3)
	expect(trace.stops).toEqual({ false })
	expect(trace.interrupts).toEqual({ "Movement.Sprint" })
	expect(TestUtils.active(created)).toEqual({})
end)

it("refuses Interrupt when the wire contract does not permit input interruption", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	started(created, 1, "Stance.Guard")
	TestUtils.interrupt(created, 2, 1, "FocusLost")
	TestUtils.expectRejected(created, 2, "ActionInterruptNotAllowed")
	expect(trace.interrupts).toEqual({})
	expect(#TestUtils.active(created)).toBe(1)
end)

it("refuses a duplicate Interrupt after the first terminated the Action", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	started(created, 1, "Movement.Sprint")
	TestUtils.interrupt(created, 2, 1, "FocusLost")
	TestUtils.interrupt(created, 3, 1, "FocusLost")
	TestUtils.expectAccepted(created, 2)
	TestUtils.expectRejected(created, 3, "ActionReceiptUnknown")
	expect(trace.interrupts).toEqual({ "Movement.Sprint" })
end)

it("keeps a long-running receipt stoppable after N9 outcome history has expired", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	started(created, 1, "Movement.Sprint")

	-- Exceed both the 128 record and 30 second history bounds with unrelated outcomes.
	for requestId: number = 2, 140 do
		created.commands.now += 1
		TestUtils.interrupt(created, requestId, 1000 + requestId, "FocusLost")
	end

	created.commands.now += 60
	TestUtils.stop(created, 141, 1, "Movement.Sprint")
	TestUtils.expectAccepted(created, 141)
	expect(trace.stops).toEqual({ false })
	expect(#TestUtils.active(created)).toBe(1)
end)

it("retires the receipt when the server interrupts the original Action", function()
	local created: TestUtils.Fixture = setup()
	local sequenceId: number = started(created, 1, "Movement.Sprint")
	TestUtils.controller(created, created.commands.actor):InterruptAction(sequenceId, "ServerCancelled")
	expect(created.runtime:_GetReceiptCountForTests()).toBe(0)
end)

it("retires receipts when the original Actor's ActionController is destroyed", function()
	local created: TestUtils.Fixture = setup()
	started(created, 1, "Movement.Sprint")
	TestUtils.controller(created, created.commands.actor):Destroy()
	expect(created.runtime:_GetReceiptCountForTests()).toBe(0)
end)
