--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local Types = require(KRF.server.Networking.types)
local ActorTypes = require(KRF.server.Actor.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Registry = require(KRF.server.Networking.CommandRegistry)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Codec: SharedTypes.CommandCodecModule = require(KRF.shared.Networking.CommandCodec)
local Constants = require(KRF.shared.Networking.utils.CommandConstants)
local AwarenessUtils = require(script.Parent.AwarenessTestUtils)
local Runtime: Types.ServerCommandRuntimeModule = require(KRF.server.Networking.ServerCommandRuntime)

export type Fixture = {
	base: AwarenessUtils.Fixture,
	awareness: Types.ActorAwarenessRuntime,
	runtime: Types.ServerCommandRuntime,
	codec: SharedTypes.CommandCodec,
	protocol: SharedTypes.ClientProtocol,
	player: Player,
	other: Player,
	actor: ActorTypes.Actor,
	now: number,
	faults: { string },
	closed: { Player },
	dependencies: Types.ServerCommandDependencies,
}

local TestUtils = {}

function TestUtils.definition(id: string, target: ("None" | "Actor")?): Types.CommandDefinition
	return {
		id = id,
		target = target or "None",
		authorize = function(): (boolean, string?)
			return true, nil
		end,
		handle = function(): Types.CommandHandlerResult
			return { accepted = true }
		end,
	}
end

function TestUtils.new(definitions: { Types.CommandDefinition }, limits: Types.ServerCommandLimits?): Fixture
	local base: AwarenessUtils.Fixture = AwarenessUtils.new()
	AwarenessUtils.start(base)
	local player: Player = AwarenessUtils.player(base)
	local other: Player = AwarenessUtils.player(base)
	AwarenessUtils.ready(base, player)
	AwarenessUtils.ready(base, other)
	local actor: ActorTypes.Actor = AwarenessUtils.actor(base, player)
	AwarenessUtils.drain(base)
	base.deliveries = {}

	return TestUtils.bind(base, player, other, actor, definitions, limits)
end

function TestUtils.bind(
	base: AwarenessUtils.Fixture,
	player: Player,
	other: Player,
	actor: ActorTypes.Actor,
	definitions: { Types.CommandDefinition },
	limits: Types.ServerCommandLimits?
): Fixture
	local awareness: Types.ActorAwarenessRuntime? = base.runtime
	assert(awareness ~= nil, "Expected real N4 runtime")
	local catalog: Types.PreparedCommandCatalog?, reason: string? = Registry.Prepare(definitions)
	assert(catalog ~= nil, reason)
	local prepared: SharedTypes.PreparedProtocol?, prepareReason: string? = Networking.Prepare(base.catalog, catalog)
	assert(prepared ~= nil, prepareReason)

	local fixture: Fixture = {
		base = base,
		awareness = awareness,
		runtime = {} :: Types.ServerCommandRuntime,
		codec = Codec.Compile(prepared.runtime),
		protocol = prepared.runtime,
		player = player,
		other = other,
		actor = actor,
		now = 100,
		faults = {},
		closed = {},
		dependencies = {} :: Types.ServerCommandDependencies,
	}

	fixture.dependencies = {
		Now = function(): number
			return fixture.now
		end,
		IsClientReady = base.dependencies.IsClientReady,
		ObserveClientClosed = base.dependencies.ObserveClientClosed,
		awareness = awareness,
		ReportFault = function(_player: Player, fault: string): ()
			table.insert(fixture.faults, fault)
		end,
		CloseConnection = function(recipient: Player, _fault: string): ()
			table.insert(fixture.closed, recipient)
			AwarenessUtils.close(base, recipient)
		end,
	}

	fixture.runtime = Runtime.new(catalog, prepared.runtime, fixture.dependencies, limits)

	return fixture
end

function TestUtils.request(
	fixture: Fixture,
	id: number,
	commandId: string?,
	player: Player?,
	actor: ActorTypes.Actor?,
	payload: any
): buffer
	local byId: { [string]: SharedTypes.ClientCommand }? = fixture.protocol.commandsById
	assert(byId ~= nil, "Expected command codebook")
	local command: SharedTypes.ClientCommand = byId[commandId or "Game.Command"]

	local encoded: buffer?, reason: string? = fixture.codec.EncodeRequest({
		commandCode = command.code,
		requestId = id,
		targetHandle = if actor ~= nil then fixture.awareness:GetHandle(player or fixture.player, actor) else nil,
		request = payload,
	})

	assert(encoded ~= nil, reason)

	return encoded
end

function TestUtils.send(
	fixture: Fixture,
	id: number,
	payload: any?,
	actor: ActorTypes.Actor?,
	commandId: string?,
	player: Player?
): (boolean, string?)
	return fixture.runtime:Handle(
		player or fixture.player,
		TestUtils.request(fixture, id, commandId, player, actor, payload)
	)
end

function TestUtils.results(fixture: Fixture, player: Player?): { SharedTypes.CommandResult }
	AwarenessUtils.drain(fixture.base)
	local results: { SharedTypes.CommandResult } = {}

	for _, delivery: AwarenessUtils.Delivery in fixture.base.deliveries do
		if
			delivery.player == (player or fixture.player)
			and buffer.readu8(delivery.payload, 0) == Constants.RESULT_KIND
		then
			local result: SharedTypes.CommandResult?, reason: string? = fixture.codec.DecodeResult(delivery.payload)
			expect(reason).toBeNil()
			assert(result ~= nil, "Expected valid result")
			table.insert(results, result)
		end
	end

	return results
end

function TestUtils.destroy(fixture: Fixture?): ()
	if fixture ~= nil then
		fixture.runtime:Destroy()
		AwarenessUtils.destroy(fixture.base)
	end
end

return TestUtils
