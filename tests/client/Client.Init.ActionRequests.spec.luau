--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ClientTypes = require(KRF.client.types)
local Types = require(KRF.client.ActionRequest.types)
local PublicTypes = require(KRF.client.Actor.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ActionRequestTypes = require(KRF.shared.ActionRequest.types)
local Client: ClientTypes.Client = require(KRF.client)
local Native = require(KRF.client.Networking.utils.NativeClientDependencies)
local State = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local Catalog: ActionRequestTypes.ActionRequestCatalogModule = require(KRF.shared.ActionRequest.ActionRequestCatalog)
local CommandCodec: SharedTypes.CommandCodecModule = require(KRF.shared.Networking.CommandCodec)
local NetworkingTypes = require(KRF.client.Networking.types)
local Commands: NetworkingTypes.CommandRuntime = require(KRF.client.Networking.CommandRuntime)
local CommandUtils = require(script.Parent.Utils.CommandClientTestUtils)
local ClientUtils = require(script.Parent.Utils.ClientTestUtils)
local RequestUtils = require(script.Parent.Utils.ActionRequestClientTestUtils)
local SharedRequestUtils = require(script.Parent.Parent.shared.Utils.ActionRequestTestUtils)
local Clock = require(script.Parent.Parent.shared.Utils.TestClock)
local clock = Clock.new()
local commandFixture: CommandUtils.Fixture? = nil

beforeEach(function()
	Client._ResetForTests()
	clock = Clock.new(100)
end)

afterEach(function()
	if commandFixture ~= nil then
		commandFixture.cleanup()
		commandFixture = nil
	end

	Client._ResetForTests()
end)

-- Production consumer installation with real command, ActorStream and ActorView owners.
local function installing(): CommandUtils.Fixture
	local fixture: CommandUtils.Fixture = CommandUtils.new()
	commandFixture = fixture
	Native.Now = clock.Now
	Native.ScheduleTimeout = clock.Schedule

	return fixture
end

local function startConfigured(config: any): ClientUtils.Fixture
	local fixture: ClientUtils.Fixture = ClientUtils.new()
	ClientUtils.start(fixture, config)

	return fixture
end

local function expectRefusedBeforeHandshake(fixture: ClientUtils.Fixture, failure: ClientTypes.StartupFailure): ()
	assert(fixture.result ~= nil, "Invalid configuration must fail before awaiting the server")
	expect(fixture.result).toEqual({ success = false, failure = failure })
	expect(fixture.sent).toEqual({})
	expect(fixture.listening).toBe(false)
	expect(Client._IsInitialized()).toBe(false)
	expect(State.Get()).toBeNil()
end

it("rejects an invalid shared request schema module before contacting the server", function()
	local fixture: ClientUtils.Fixture =
		startConfigured({ actionRequestSchemas = { ["Combat.Fireball"] = { onDisconnect = "Forever" } } })

	expectRefusedBeforeHandshake(fixture, { system = "ActionRequest", reason = "ActionRequestDisconnectPolicyInvalid" })
end)

it("rejects a non-table client configuration", function()
	expectRefusedBeforeHandshake(startConfigured(true), { system = "Client", reason = "ClientConfigInvalid" })
end)

it("rejects an unknown client configuration field", function()
	expectRefusedBeforeHandshake(
		startConfigured({ inputs = {} }),
		{ system = "Client", reason = "ClientConfigFieldUnknown" }
	)
end)

it("starts unchanged with an empty configuration and installs no Action request runtime", function()
	local fixture: ClientUtils.Fixture = startConfigured({})
	ClientUtils.bootstrap(fixture)
	ClientUtils.acknowledge(fixture)
	expect(fixture.result).toEqual({ success = true })
	expect(State.Get()).toBeNil()
end)

it("fails startup without READY when the server published no Action request commands", function()
	local fixture: CommandUtils.Fixture = installing()
	CommandUtils.start(fixture, { actionRequestSchemas = SharedRequestUtils.schemas() })
	CommandUtils.bootstrap(fixture)

	local result: ClientUtils.InitResult? = fixture.client.result
	assert(result ~= nil, "A missing server contract must fail startup immediately")

	expect(result).toEqual({
		success = false,
		failure = { system = "ActionRequest", reason = "ActionRequestCommandsUnavailable" },
	})

	expect(fixture.client.order).never.toContain("Ready")
	expect(State.Get()).toBeNil()
end)

it("installs the Action request runtime before READY and removes it on reset", function()
	local fixture: CommandUtils.Fixture = installing()
	CommandUtils.start(fixture, { actionRequestSchemas = SharedRequestUtils.schemas() })
	CommandUtils.bootstrap(fixture, RequestUtils.manifestCommands())
	expect(State.Get()).never.toBeNil()
	ClientUtils.acknowledge(fixture.client)
	expect(fixture.client.result).toEqual({ success = true })
	expect(State.Get()).never.toBeNil()
	Client._ResetForTests()
	expect(State.Get()).toBeNil()
end)

it("installs no Action request runtime when the client omits request schemas", function()
	local fixture: CommandUtils.Fixture = installing()
	CommandUtils.ready(fixture, nil, RequestUtils.manifestCommands())
	expect(State.Get()).toBeNil()
end)

it("sends a typed Start through the real command runtime with the shared contract tag", function()
	local fixture: CommandUtils.Fixture = installing()
	local schemas: ActionRequestTypes.ActionRequestSchemas = SharedRequestUtils.schemas()
	CommandUtils.ready(fixture, { actionRequestSchemas = schemas }, RequestUtils.manifestCommands())
	local view: PublicTypes.ActorView = CommandUtils.baseline(fixture)
	local runtime: Types.ClientActionRequestRuntime? = State.Get()
	assert(runtime ~= nil, "Expected the installed Action request runtime")

	local aim: any = { x = 1, y = 0, z = -1 }

	local requestId: number?, reason: string? = runtime:Start(
		{ actor = view, actionId = "Combat.Fireball", origin = "Direct" },
		{ aim = aim }
	)

	expect(reason).toBeNil()
	expect(requestId).toBe(1)

	local catalog: ActionRequestTypes.ActionRequestCatalog? = Catalog.Compile(schemas)
	assert(catalog ~= nil and fixture.protocol ~= nil, "Expected the shared catalog and protocol")
	local fireball: ActionRequestTypes.CompiledActionRequest = SharedRequestUtils.request(catalog, "Combat.Fireball")
	local decoded: SharedTypes.CommandRequest? = CommandCodec.Compile(fixture.protocol).DecodeRequest(fixture.sent[1])
	assert(decoded ~= nil, "Expected a decodable Start packet")

	expect(decoded.commandCode).toBe(2)
	expect(decoded.targetHandle).toBe(7)

	expect(decoded.request).toEqual({
		actionId = "Combat.Fireball",
		contractTag = fireball.contractTag,
		payload = SharedRequestUtils.encode(fireball.start, { aim = aim }),
	})
end)

it("still admits Stop and Interrupt for a running Sprint after ordinary commands fill their pending share", function()
	local fixture: CommandUtils.Fixture = installing()

	CommandUtils.ready(
		fixture,
		{ actionRequestSchemas = SharedRequestUtils.schemas() },
		RequestUtils.manifestCommands()
	)

	local view: PublicTypes.ActorView = CommandUtils.baseline(fixture)
	local runtime: Types.ClientActionRequestRuntime? = State.Get()
	assert(runtime ~= nil, "Expected the installed Action request runtime")

	local sprint: number? = runtime:Start({ actor = view, actionId = "Movement.Sprint", origin = "Input" }, nil)
	assert(sprint ~= nil, "Expected the original Sprint Start")

	local refusal: string? = nil

	while refusal == nil do
		local requestId: number?, reason: string? = Commands.Send("Game.Ping")

		if requestId == nil then
			refusal = reason
		end
	end

	expect(refusal).toBe("CommandPendingFull")

	-- An ordinary Start shares the ordinary bound and is refused with it.
	local blocked: number?, blockedReason: string? =
		runtime:Start({ actor = view, actionId = "Movement.Sprint", origin = "Input" }, nil)

	expect(blocked).toBeNil()
	expect(blockedReason).toBe("CommandPendingFull")

	local stop: number?, stopReason: string? = runtime:Stop(sprint, nil)
	expect(stopReason).toBeNil()
	expect(stop).never.toBeNil()

	local interrupt: number?, interruptReason: string? = runtime:Interrupt(sprint, "FocusLost")
	expect(interruptReason).toBeNil()
	expect(interrupt).never.toBeNil()
end)
