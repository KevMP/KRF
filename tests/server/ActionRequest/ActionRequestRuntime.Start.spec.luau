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
local RequestUtils = require(script.Parent.Parent.Parent.shared.Utils.ActionRequestTestUtils)

local fixture: TestUtils.Fixture? = nil

afterEach(function()
	TestUtils.destroy(fixture)
	fixture = nil
end)

local aim: SharedTypes.SchemaDefinition = Schema.Struct({ x = Schema.F32, y = Schema.F32, z = Schema.F32 })

local schemas: ActionRequestTypes.ActionRequestSchemas = {
	["Combat.Fireball"] = { start = Schema.Struct({ aim = aim }) },
	["Movement.Sprint"] = {
		stop = {},
		allowInputInterrupt = true,
		requiresClientRelease = true,
		onDisconnect = "Interrupt",
	},
	["Technique.Cast"] = { start = Schema.Struct({ techniqueId = Schema.String(64) }) },
}

type Trace = { canStart: { any }, started: { any } }

local function definitions(trace: Trace, overrides: { [string]: { [string]: any } }?): { ActionTypes.ActionDefinition }
	local result: { ActionTypes.ActionDefinition } = {}

	for _, entry in
		{
			{ id = "Combat.Fireball", visibility = "ClientVisible" },
			{ id = "Movement.Sprint", visibility = "ClientVisible" },
			{ id = "Technique.Cast", visibility = "ServerOnly" },
			{ id = "Combat.Unregistered", visibility = "ClientVisible" },
		}
	do
		local definition: ActionTypes.ActionDefinition = {
			id = entry.id,
			visibility = entry.visibility :: ActionTypes.ActionVisibility,
			autoGrant = true,
			onCanStart = function(context: ActionTypes.ActionStartContext): (boolean, string?)
				table.insert(trace.canStart, context.parameters)

				return true, nil
			end,
			onStart = function(context: ActionTypes.ActionExecutionContext): ()
				table.insert(trace.started, context.parameters)
			end,
		}

		for key: string, value: any in (if overrides ~= nil then overrides[entry.id] else nil) or {} do
			(definition :: any)[key] = value
		end

		table.insert(result, definition)
	end

	return result
end

local function setup(
	overrides: { [string]: { [string]: any } }?,
	options: TestUtils.Options?
): (TestUtils.Fixture, Trace)
	local trace: Trace = { canStart = {}, started = {} }
	local created: TestUtils.Fixture = TestUtils.new(definitions(trace, overrides), schemas, options)
	fixture = created

	return created, trace
end

it("starts the requested Action on the original Actor and returns its real sequence id", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	local parameters: any = { aim = { x = 1, y = 2, z = 3 } }
	expect({ TestUtils.start(created, 1, "Combat.Fireball", parameters) }).toEqual({ true })

	local result: any = TestUtils.expectAccepted(created, 1)
	local active: { ActionTypes.ActionReplicationIdentity } = TestUtils.active(created)
	expect(#active).toBe(1)
	expect(active[1].actionId).toBe("Combat.Fireball")
	expect(result).toEqual({ sequenceId = active[1].sequenceId })
	expect(trace.canStart).toEqual({ parameters })
	expect(trace.started).toEqual({ parameters })
end)

it("starts a parameterless Action from an empty inner payload", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	TestUtils.start(created, 1, "Movement.Sprint")
	TestUtils.expectAccepted(created, 1)
	expect(#trace.started).toBe(1)
	expect(trace.started[1]).toBeNil()
end)

it("starts an explicitly registered ServerOnly Action without an ActionsView", function()
	local created: TestUtils.Fixture = setup()
	TestUtils.start(created, 1, "Technique.Cast", { techniqueId = "Chidori" })
	TestUtils.expectAccepted(created, 1)
	expect(TestUtils.active(created)[1].actionId).toBe("Technique.Cast")
end)

it("rejects a granted visible Action that has no registered request schema", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	TestUtils.start(created, 1, "Combat.Unregistered")
	TestUtils.expectRejected(created, 1, "ActionRequestUnregistered")
	expect(trace.canStart).toEqual({})
end)

it("rejects a contract tag mismatch before decoding or gameplay checks", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	local request: ActionRequestTypes.CompiledActionRequest = created.catalog.requestsById["Combat.Fireball"]

	TestUtils.start(created, 1, "Combat.Fireball", { aim = { x = 0, y = 0, z = 0 } }, {
		contractTag = request.contractTag + 1,
	})

	TestUtils.expectRejected(created, 1, "ActionContractMismatch")
	expect(trace.canStart).toEqual({})
end)

type PayloadCase = { label: string, actionId: string, payload: string, reason: string }

local payloadCases: { PayloadCase } = {
	{ label = "malformed bytes", actionId = "Combat.Fireball", payload = "\1\2", reason = "ActionPayloadMalformed" },
	{ label = "a missing payload", actionId = "Combat.Fireball", payload = "", reason = "ActionPayloadMalformed" },
	{
		label = "bytes for a parameterless Start",
		actionId = "Movement.Sprint",
		payload = "\0",
		reason = "ActionPayloadTrailingBytes",
	},
}

for _, payloadCase: PayloadCase in payloadCases do
	it("rejects " .. payloadCase.label .. " before any ActionController work", function()
		local created: TestUtils.Fixture, trace: Trace = setup()
		TestUtils.start(created, 1, payloadCase.actionId, nil, { payload = payloadCase.payload })
		TestUtils.expectRejected(created, 1, payloadCase.reason)
		expect(trace.canStart).toEqual({})
		expect(TestUtils.active(created)).toEqual({})
	end)
end

it("rejects trailing bytes after a complete typed Start before any ActionController work", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	local request: ActionRequestTypes.CompiledActionRequest = created.catalog.requestsById["Combat.Fireball"]
	local encoded: string = RequestUtils.encode(request.start, { aim = { x = 1, y = 1, z = 1 } })
	TestUtils.start(created, 1, "Combat.Fireball", nil, { payload = encoded .. "\0" })
	TestUtils.expectRejected(created, 1, "ActionPayloadTrailingBytes")
	expect(trace.canStart).toEqual({})
end)

it("rejects a Start targeting an Actor the Player neither owns nor is delegated", function()
	local created: TestUtils.Fixture, trace: Trace = setup()
	local foreign: ActorTypes.Actor = TestUtils.actor(created, created.commands.other)
	TestUtils.start(created, 1, "Combat.Fireball", { aim = { x = 0, y = 0, z = 0 } }, { actor = foreign })
	TestUtils.expectRejected(created, 1, "ActorNotOwned")
	expect(trace.canStart).toEqual({})
end)

it("starts on a server-authorized delegated mount without granting other Players control", function()
	local mount: ActorTypes.Actor? = nil
	local rider: Player? = nil

	local created: TestUtils.Fixture = setup(nil, {
		authorizeControl = function(player: Player, actor: ActorTypes.Actor): boolean
			return player == rider and actor == mount
		end,
	})

	rider = created.commands.player
	mount = TestUtils.actor(created, nil)
	TestUtils.start(created, 1, "Movement.Sprint", nil, { actor = mount })
	TestUtils.expectAccepted(created, 1)
	expect(TestUtils.active(created, mount)[1].actionId).toBe("Movement.Sprint")

	TestUtils.start(created, 1, "Movement.Sprint", nil, { actor = mount, player = created.commands.other })
	TestUtils.expectRejected(created, 1, "ActorNotOwned", created.commands.other)
end)

it("lets existing onCanStart deny a granted but unequipped Action with its own bounded reason", function()
	local created: TestUtils.Fixture = setup({
		["Combat.Fireball"] = {
			onCanStart = function(): (boolean, string?)
				return false, "FireballNotEquipped"
			end,
		},
	})

	TestUtils.start(created, 1, "Combat.Fireball", { aim = { x = 0, y = 0, z = 0 } })
	TestUtils.expectRejected(created, 1, "FireballNotEquipped")
	expect(TestUtils.active(created)).toEqual({})
end)

it("lets existing grants deny an ungranted registered Action", function()
	local created: TestUtils.Fixture = setup({ ["Combat.Fireball"] = { autoGrant = false } })
	TestUtils.start(created, 1, "Combat.Fireball", { aim = { x = 0, y = 0, z = 0 } })
	TestUtils.expectRejected(created, 1, "ActionNotGranted")
end)

for _, denial: string in { string.rep("x", 65), "Bad\255Reason" } do
	it("normalizes an unbounded consumer denial reason into a bounded Rejected outcome", function()
		local created: TestUtils.Fixture = setup({
			["Combat.Fireball"] = {
				onCanStart = function(): (boolean, string?)
					return false, denial
				end,
			},
		})

		TestUtils.start(created, 1, "Combat.Fireball", { aim = { x = 0, y = 0, z = 0 } })
		TestUtils.expectRejected(created, 1, "ActionRequestRejected")
	end)
end

it("rejects without effects when onCanStart revokes the original Actor's ownership", function()
	local revoke: (() -> ())? = nil

	local created: TestUtils.Fixture, trace: Trace = setup({
		["Combat.Fireball"] = {
			onCanStart = function(): (boolean, string?)
				if revoke ~= nil then
					revoke()
				end

				return true, nil
			end,
		},
	})

	revoke = function(): ()
		TestUtils.associate(created, created.commands.actor, nil)
	end

	TestUtils.start(created, 1, "Combat.Fireball", { aim = { x = 0, y = 0, z = 0 } })
	TestUtils.expectRejected(created, 1, "ActorNotOwned")
	expect(trace.started).toEqual({})
	expect(TestUtils.active(created)).toEqual({})
	expect(created.runtime:_GetReceiptCountForTests()).toBe(0)
end)

it("rejects before ActionController work when the connection's receipt capacity is full", function()
	local created: TestUtils.Fixture, trace: Trace = setup(nil, { receiptLimits = { maxConnectionReceipts = 1 } })
	TestUtils.start(created, 1, "Movement.Sprint")
	TestUtils.expectAccepted(created, 1)
	TestUtils.start(created, 2, "Movement.Sprint")
	TestUtils.expectRejected(created, 2, "ActionReceiptCapacityReached")
	expect(#trace.canStart).toBe(1)
	expect(#TestUtils.active(created)).toBe(1)
end)

it("returns Accepted with a real sequence id but retains no receipt when onStart ends immediately", function()
	local created: TestUtils.Fixture = setup({
		["Movement.Sprint"] = {
			onStart = function(context: ActionTypes.ActionExecutionContext): ()
				context:End()
			end,
		},
	})

	TestUtils.start(created, 1, "Movement.Sprint")
	local result: any = TestUtils.expectAccepted(created, 1)
	expect(type(result.sequenceId)).toBe("number")
	expect(result.sequenceId >= 1).toBe(true)
	expect(TestUtils.active(created)).toEqual({})
	expect(created.runtime:_GetReceiptCountForTests()).toBe(0)
end)

it("retains exactly one live receipt for a still-active accepted Start", function()
	local created: TestUtils.Fixture = setup()
	TestUtils.start(created, 1, "Movement.Sprint")
	TestUtils.expectAccepted(created, 1)
	expect(created.runtime:_GetReceiptCountForTests()).toBe(1)
end)

it("retires a rejected Start's provisional receipt", function()
	local created: TestUtils.Fixture = setup({
		["Movement.Sprint"] = {
			onCanStart = function(): (boolean, string?)
				return false, "Exhausted"
			end,
		},
	})

	TestUtils.start(created, 1, "Movement.Sprint")
	TestUtils.expectRejected(created, 1, "Exhausted")
	expect(created.runtime:_GetReceiptCountForTests()).toBe(0)
end)
