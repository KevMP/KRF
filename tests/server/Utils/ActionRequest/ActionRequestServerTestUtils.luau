--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local Types = require(KRF.server.ActionRequest.types)
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ActionRequestTypes = require(KRF.shared.ActionRequest.types)
local Constants = require(KRF.shared.ActionRequest.utils.ActionRequestConstants)
local ActionRegistry = require(KRF.server.Action.ActionRegistry)
local ActionController = require(KRF.server.Action.ActionController)
local Runtime: Types.ActionRequestRuntimeModule = require(KRF.server.ActionRequest.ActionRequestRuntime)
local Commands = require(script.Parent.Parent.Networking.CommandRuntimeTestUtils)
local AwarenessUtils = require(script.Parent.Parent.Networking.AwarenessTestUtils)
local RequestUtils = require(script.Parent.Parent.Parent.Parent.shared.Utils.ActionRequestTestUtils)

export type Fixture = {
	commands: Commands.Fixture,
	runtime: Types.ServerActionRequestRuntime,
	catalog: ActionRequestTypes.ActionRequestCatalog,
	controllers: { [ActorTypes.Actor]: ActionTypes.InternalActionController },
}

export type Options = {
	authorizeControl: Types.ActionControlAuthority?,
	receiptLimits: Types.ActionReceiptLimits?,
}

export type SendOptions = {
	player: Player?,
	actor: ActorTypes.Actor?,
	contractTag: number?,
	payload: string?,
}

local TestUtils = {}

function TestUtils.new(
	definitions: { ActionTypes.ActionDefinition },
	schemas: ActionRequestTypes.ActionRequestSchemas,
	options: Options?
): Fixture
	ActionRegistry._resetForTests()
	local factories: { ActionTypes.ActionFactory } = {}

	for _, definition: ActionTypes.ActionDefinition in definitions do
		local source: ActionTypes.ActionDefinition = definition

		table.insert(factories, function(): ActionTypes.ActionDefinition
			return table.clone(source)
		end)
	end

	local loaded: boolean, loadReason: string? = ActionRegistry.Load(factories, {}, {})
	assert(loaded, loadReason)

	local catalog: ActionRequestTypes.ActionRequestCatalog = RequestUtils.catalog(schemas)
	local controllers: { [ActorTypes.Actor]: ActionTypes.InternalActionController } = {}

	local runtime: Types.ServerActionRequestRuntime = Runtime.new(catalog, {
		GetActionController = function(actor: ActorTypes.Actor): ActionTypes.InternalActionController?
			return controllers[actor]
		end,
		AuthorizeControl = if options ~= nil then options.authorizeControl else nil,
	}, { receiptLimits = if options ~= nil then options.receiptLimits else nil })

	local commands: Commands.Fixture = Commands.new(runtime:GetCommandDefinitions())

	local fixture: Fixture = {
		commands = commands,
		runtime = runtime,
		catalog = catalog,
		controllers = controllers,
	}

	TestUtils.controller(fixture, commands.actor)

	return fixture
end

function TestUtils.controller(fixture: Fixture, actor: ActorTypes.Actor): ActionTypes.InternalActionController
	local existing: ActionTypes.InternalActionController? = fixture.controllers[actor]

	if existing ~= nil then
		return existing
	end

	local created: ActionTypes.InternalActionController =
		ActionController.new(actor) :: ActionTypes.InternalActionController

	fixture.controllers[actor] = created

	return created
end

-- Another Player's Character, visible to every ready client after awareness drains.
function TestUtils.actor(fixture: Fixture, owner: Player?): ActorTypes.Actor
	local actor: ActorTypes.Actor = AwarenessUtils.actor(fixture.commands.base, owner)
	AwarenessUtils.drain(fixture.commands.base)
	TestUtils.controller(fixture, actor)

	return actor
end

function TestUtils.associate(fixture: Fixture, actor: ActorTypes.Actor, player: Player?): ()
	AwarenessUtils.associate(fixture.commands.base, actor, player)
end

function TestUtils.start(
	fixture: Fixture,
	requestId: number,
	actionId: string,
	parameters: any?,
	options: SendOptions?
): (boolean, string?)
	local request: ActionRequestTypes.CompiledActionRequest? = fixture.catalog.requestsById[actionId]
	local sent: SendOptions = options or {}

	return Commands.send(fixture.commands, requestId, {
		actionId = actionId,
		contractTag = sent.contractTag or (if request ~= nil then request.contractTag else 0),
		payload = sent.payload or (if request ~= nil then RequestUtils.encode(request.start, parameters) else ""),
	}, sent.actor or fixture.commands.actor, Constants.START_COMMAND_ID, sent.player)
end

function TestUtils.stop(
	fixture: Fixture,
	requestId: number,
	originalStartRequestId: number,
	actionId: string,
	parameters: any?,
	options: SendOptions?
): (boolean, string?)
	local sent: SendOptions = options or {}
	local request: ActionRequestTypes.CompiledActionRequest? = fixture.catalog.requestsById[actionId]
	local stop: ActionRequestTypes.CompiledActionPayload? = if request ~= nil then request.stop else nil

	return Commands.send(fixture.commands, requestId, {
		originalStartRequestId = originalStartRequestId,
		payload = sent.payload or (if stop ~= nil then RequestUtils.encode(stop, parameters) else ""),
	}, nil, Constants.STOP_COMMAND_ID, sent.player)
end

function TestUtils.interrupt(
	fixture: Fixture,
	requestId: number,
	originalStartRequestId: number,
	reason: ActionRequestTypes.ActionInputInterruptReason,
	player: Player?
): (boolean, string?)
	return Commands.send(fixture.commands, requestId, {
		originalStartRequestId = originalStartRequestId,
		reason = reason,
	}, nil, Constants.INTERRUPT_COMMAND_ID, player)
end

function TestUtils.result(fixture: Fixture, requestId: number, player: Player?): SharedTypes.CommandResult
	local found: SharedTypes.CommandResult? = nil

	for _, result: SharedTypes.CommandResult in Commands.results(fixture.commands, player) do
		if result.requestId == requestId then
			found = result
		end
	end

	assert(found ~= nil, "Expected a command result for request " .. requestId)

	return found
end

function TestUtils.expectAccepted(fixture: Fixture, requestId: number, player: Player?): any
	local result: SharedTypes.CommandResult = TestUtils.result(fixture, requestId, player)
	expect(result.reason).toBeNil()
	expect(result.status).toBe("Accepted")

	return result.result
end

function TestUtils.expectRejected(fixture: Fixture, requestId: number, reason: string, player: Player?): ()
	local result: SharedTypes.CommandResult = TestUtils.result(fixture, requestId, player)
	expect(result.status).toBe("Rejected")
	expect(result.reason).toBe(reason)
end

function TestUtils.close(fixture: Fixture, player: Player?): ()
	AwarenessUtils.close(fixture.commands.base, player or fixture.commands.player)
end

function TestUtils.reconnect(fixture: Fixture, player: Player?): ()
	AwarenessUtils.ready(fixture.commands.base, player or fixture.commands.player)
	AwarenessUtils.drain(fixture.commands.base)
	fixture.commands.base.deliveries = {}
end

function TestUtils.active(fixture: Fixture, actor: ActorTypes.Actor?): { ActionTypes.ActionReplicationIdentity }
	return TestUtils.controller(fixture, actor or fixture.commands.actor):_getActiveReplicationState()
end

function TestUtils.destroy(fixture: Fixture?): ()
	if fixture == nil then
		return
	end

	fixture.runtime:Destroy()

	for _, controller: ActionTypes.InternalActionController in fixture.controllers do
		controller:Destroy()
	end

	Commands.destroy(fixture.commands)
	ActionRegistry._resetForTests()
end

return TestUtils
