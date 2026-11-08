--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ServerTypes = require(KRF.server.types)
local ActionTypes = require(KRF.server.Action.types)
local SharedTypes = require(KRF.shared.Networking.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local Server = require(KRF.server)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Controllers = require(KRF.server.Controller.ControllerRegistry)
local Tags = require(KRF.server.Tags.TagRegistry)
local Resources = require(KRF.server.Resource.ResourceRegistry)
local Actions = require(KRF.server.Action.ActionRegistry)
local Domains = require(KRF.server.Replication.ReplicationDomainRegistry)
local Registry = require(KRF.server.Networking.CommandRegistry)
local Transport = require(KRF.shared.Networking.Transport)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Constants = require(KRF.shared.ActionRequest.utils.ActionRequestConstants)
local ActorTypes = require(KRF.server.Actor.types)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local ActionController = require(KRF.server.Action.ActionController)
local CommandContext = require(KRF.server.Networking.utils.CommandContext)
local ActionRequestCatalog = require(KRF.shared.ActionRequest.ActionRequestCatalog)
local Commands = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)
local ProtocolUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local RequestUtils = require(script.Parent.Parent.Parent.shared.Utils.ActionRequestTestUtils)

local originalPublish: typeof(Networking.Publish) = Networking.Publish

beforeEach(function()
	Server._ResetForTests()
end)

afterEach(function()
	Networking.Publish = originalPublish
	Server._ResetForTests()
end)

local function action(id: string, visibility: ActionTypes.ActionVisibility?): ActionTypes.ActionFactory
	return function(): ActionTypes.ActionDefinition
		return { id = id, visibility = visibility or "ClientVisible", autoGrant = true }
	end
end

local function representativeActions(): { ActionTypes.ActionFactory }
	return { action("Combat.Fireball"), action("Movement.Sprint"), action("Technique.Cast", "ServerOnly") }
end

local function expectUnpublished(): ()
	expect(Server._IsInitialized()).toBe(false)
	expect(Networking._IsInitialized()).toBe(false)
	expect(Controllers.IsLoaded()).toBe(false)
	expect(Tags.IsLoaded()).toBe(false)
	expect(Resources.IsLoaded()).toBe(false)
	expect(Actions.IsLoaded()).toBe(false)
	expect(Domains.IsLoaded()).toBe(false)
	expect(Registry.IsLoaded()).toBe(false)
	expect(Registry.Get(Constants.START_COMMAND_ID)).toBeNil()
	expect(ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME)).toBeNil()
end

local function expectRejected(config: any, failure: ServerTypes.StartupFailure): ()
	local success: boolean, reason: ServerTypes.StartupFailure? = Server.Init(config)
	expect(success).toBe(false)
	expect(reason).toEqual(failure)
	expectUnpublished()
end

local function field(schema: SharedTypes.CompiledSchema?, name: string): SharedTypes.CompiledSchema
	assert(schema ~= nil and schema.kind == "Struct", "Expected a Struct command envelope")
	local nested: SharedTypes.CompiledSchema? = schema.fieldsByName[name]
	assert(nested ~= nil, "Expected envelope field " .. name)

	return nested
end

it("registers no Action commands when request schemas are omitted", function()
	local success: boolean = Server.Init({ actions = representativeActions() })
	expect(success).toBe(true)
	expect(Registry.Get(Constants.START_COMMAND_ID)).toBeNil()
	expect(Registry.Get(Constants.STOP_COMMAND_ID)).toBeNil()
	expect(Registry.Get(Constants.INTERRUPT_COMMAND_ID)).toBeNil()
end)

it("merges exactly the three fixed Action commands with consumer commands", function()
	local success: boolean, failure: ServerTypes.StartupFailure? = Server.Init({
		actions = representativeActions(),
		commands = { Commands.definition("Game.Ping") },
		actionRequestSchemas = RequestUtils.schemas(),
	})

	expect(failure).toBeNil()
	expect(success).toBe(true)

	local ids: { string } = {}

	for _, definition: NetworkingTypes.LoadedCommandDefinition in Registry.GetAll() do
		table.insert(ids, definition.id)
	end

	expect(ids).toEqual({ "Game.Ping", "KRF.Action.Interrupt", "KRF.Action.Start", "KRF.Action.Stop" })
	-- A consumer command never joins the framework follow-up reserve.
	expect((Registry.Get("Game.Ping") :: NetworkingTypes.LoadedCommandDefinition).followUp).toBe(false)
end)

it("declares the fixed Start, Stop and Interrupt envelopes with bounded typed fields", function()
	local success: boolean =
		Server.Init({ actions = representativeActions(), actionRequestSchemas = RequestUtils.schemas() })

	expect(success).toBe(true)

	local start: NetworkingTypes.LoadedCommandDefinition? = Registry.Get(Constants.START_COMMAND_ID)
	local stop: NetworkingTypes.LoadedCommandDefinition? = Registry.Get(Constants.STOP_COMMAND_ID)
	local interrupt: NetworkingTypes.LoadedCommandDefinition? = Registry.Get(Constants.INTERRUPT_COMMAND_ID)
	assert(start ~= nil and stop ~= nil and interrupt ~= nil, "Expected the three fixed Action commands")

	expect(start.target).toBe("Actor")
	expect(stop.target).toBe("None")
	expect(interrupt.target).toBe("None")
	-- Only the lifecycle follow-ups use N9's protected admission reserve.
	expect(start.followUp).toBe(false)
	expect(stop.followUp).toBe(true)
	expect(interrupt.followUp).toBe(true)
	expect(field(start.request, "actionId")).toEqual(expect.objectContaining({ kind = "String", maxBytes = 96 }))
	expect(field(start.request, "contractTag").kind).toBe("U32")
	expect(field(start.request, "payload")).toEqual(expect.objectContaining({ kind = "String", maxBytes = 8192 }))
	expect(field(start.result, "sequenceId").kind).toBe("U32")
	expect(field(stop.request, "originalStartRequestId").kind).toBe("U32")
	expect(field(stop.request, "payload")).toEqual(expect.objectContaining({ kind = "String", maxBytes = 8192 }))
	expect(stop.result).toBeNil()
	expect(field(interrupt.request, "originalStartRequestId").kind).toBe("U32")

	expect(field(interrupt.request, "reason")).toEqual(
		expect.objectContaining({ kind = "Enum", values = table.clone(Constants.INTERRUPT_REASONS) })
	)

	expect(interrupt.result).toBeNil()
end)

it("registers the fixed commands for an empty request schema module without making any Action requestable", function()
	local success: boolean = Server.Init({ actions = representativeActions(), actionRequestSchemas = {} })
	expect(success).toBe(true)
	expect(Registry.Get(Constants.START_COMMAND_ID)).never.toBeNil()
	expect(#Registry.GetAll()).toBe(3)
end)

it("accepts an explicitly registered ServerOnly Action at startup", function()
	local success: boolean, failure: ServerTypes.StartupFailure? = Server.Init({
		actions = { action("Technique.Cast", "ServerOnly") },
		actionRequestSchemas = { ["Technique.Cast"] = RequestUtils.schemas()["Technique.Cast"] },
	})

	expect(failure).toBeNil()
	expect(success).toBe(true)
end)

it("rejects request schemas naming an Action absent from the prepared catalog", function()
	expectRejected({
		actions = { action("Combat.Fireball") },
		actionRequestSchemas = { ["Combat.Fireball"] = {}, ["Combat.Missing"] = {} },
	}, { system = "ActionRequest", reason = "ActionRequestUnknownAction" })
end)

it("rejects an invalid shared request schema module before publishing any registry", function()
	expectRejected({
		actions = representativeActions(),
		actionRequestSchemas = { ["Combat.Fireball"] = { onDisconnect = "Forever" } },
	}, { system = "ActionRequest", reason = "ActionRequestDisconnectPolicyInvalid" })
end)

it("rejects a non-table request schema module", function()
	expectRejected(
		{ actions = representativeActions(), actionRequestSchemas = "Combat.Fireball" },
		{ system = "ActionRequest", reason = "ActionRequestSchemasMustBeTable" }
	)
end)

it("rejects a non-function control authority", function()
	expectRejected({
		actions = representativeActions(),
		actionRequestSchemas = RequestUtils.schemas(),
		actionControlAuthority = true,
	}, { system = "ActionRequest", reason = "ActionControlAuthorityInvalid" })
end)

for _, reserved: string in { Constants.START_COMMAND_ID, Constants.STOP_COMMAND_ID, Constants.INTERRUPT_COMMAND_ID } do
	it("rejects a consumer command reusing the reserved id " .. reserved, function()
		local conflicting: NetworkingTypes.CommandDefinition = Commands.definition(reserved)
		conflicting.request = Schema.U8

		expectRejected({
			actions = representativeActions(),
			commands = { conflicting },
			actionRequestSchemas = RequestUtils.schemas(),
		}, { system = "Command", reason = "CommandIdReserved" })
	end)

	it("reserves " .. reserved .. " even when request schemas are omitted", function()
		expectRejected(
			{ commands = { Commands.definition(reserved) } },
			{ system = "Command", reason = "CommandIdReserved" }
		)
	end)
end

it("does not run Action factories' gameplay callbacks while validating request schemas", function()
	local calls: number = 0

	local factory: ActionTypes.ActionFactory = function(): ActionTypes.ActionDefinition
		return {
			id = "Combat.Fireball",
			visibility = "ClientVisible",
			onCanStart = function(): (boolean, string?)
				calls += 1

				return true, nil
			end,
		}
	end

	local success: boolean = Server.Init({ actions = { factory }, actionRequestSchemas = { ["Combat.Fireball"] = {} } })
	expect(success).toBe(true)
	expect(calls).toBe(0)
end)

it("rolls back the merged Action commands with every registry when transport activation fails", function()
	Networking.Publish = function(_protocol: SharedTypes.PreparedProtocol): (boolean, string?)
		expect(Registry.Get(Constants.START_COMMAND_ID)).never.toBeNil()

		return false, "TransportConflict"
	end

	expectRejected(
		{ actions = representativeActions(), actionRequestSchemas = RequestUtils.schemas() },
		{ system = "Networking", reason = "TransportConflict" }
	)
end)

it("starts a requested Action on the target Actor's own ActionController through the published command", function()
	local schemas = RequestUtils.schemas()
	local success: boolean = Server.Init({ actions = representativeActions(), actionRequestSchemas = schemas })
	expect(success).toBe(true)

	local start: NetworkingTypes.LoadedCommandDefinition? = Registry.Get(Constants.START_COMMAND_ID)
	local catalog = ActionRequestCatalog.Compile(schemas)
	assert(start ~= nil and catalog ~= nil, "Expected the published Start command and shared catalog")

	local player: Player = ProtocolUtils.createPlayer()

	local actor: ActorTypes.Actor = ActorEntity.new()
	actor.enabled = true

	local controller = ActionController.new(actor)
	actor:SetController("ActionController", controller)

	-- A real N9 invocation binding for the owner's current connection generation.
	local context: NetworkingTypes.CommandContext, close: () -> () = CommandContext.new(
		player,
		actor,
		1,
		Constants.START_COMMAND_ID,
		function(): NetworkingTypes.CommandOutcome?
			return nil
		end,
		{
			ready = function(): boolean
				return true
			end,
			owns = function(): boolean
				return true
			end,
			scope = table.freeze({
				token = table.freeze({}),
				ObserveClosing = function(): (() -> ())?
					return function(): () end
				end,
			}),
		}
	)

	local request: any = {
		actionId = "Movement.Sprint",
		contractTag = catalog.requestsById["Movement.Sprint"].contractTag,
		payload = "",
	}

	expect({ start.authorize(context, request) }).toEqual({ true })
	local result: NetworkingTypes.CommandHandlerResult = start.handle(context, request)
	expect(result.reason).toBeNil()
	expect(result.accepted).toBe(true)
	expect(result.result).toEqual({ sequenceId = controller:_getActiveReplicationState()[1].sequenceId })

	close()
	controller:Destroy()
	player:Destroy()
end)
