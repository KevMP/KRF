--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActionTypes = require(KRF.server.Action.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Server = require(KRF.server)
local Actions: ActionTypes.ActionRegistry = require(KRF.server.Action.ActionRegistry)

local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)

local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local ProtocolCodec: SharedTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local Transport = require(KRF.shared.Networking.Transport)
local DomainUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)

local originalPrepare = Networking.Prepare
local prepared: SharedTypes.PreparedProtocol? = nil

beforeEach(function()
	Server._ResetForTests()
	prepared = nil

	Networking.Prepare = function(
		catalog: ReplicationTypes.PreparedReplicationDomainCatalog
	): (SharedTypes.PreparedProtocol?, string?)
		local protocol: SharedTypes.PreparedProtocol?, reason: string? = originalPrepare(catalog)
		prepared = protocol

		return protocol, reason
	end
end)

afterEach(function()
	Networking.Prepare = originalPrepare
	Server._ResetForTests()
end)

local function action(id: string, visibility: ActionTypes.ActionVisibility): ActionTypes.ActionFactory
	return function(): ActionTypes.ActionDefinition
		return { id = id, visibility = visibility, autoGrant = true }
	end
end

local function protocol(): SharedTypes.PreparedProtocol
	assert(prepared ~= nil, "Normal startup must prepare N2")

	return prepared
end

for _, catalog: { ActionTypes.ActionFactory } in { {}, { action("Private.Secret", "ServerOnly") } } do
	it("omits Actions domain and metadata when no visible actions exist, catalog size " .. #catalog, function()
		expect(Server.Init({ actions = catalog })).toBe(true)
		expect(Domains.GetAll()).toEqual({})
		expect(protocol().manifest.domains).toEqual({})
		local decoded: SharedTypes.ProtocolMessage?, reason: string? = ProtocolCodec.Decode(protocol().bootstrapBuffer)
		expect(reason).toBeNil()
		expect(decoded).toEqual({ kind = "Bootstrap", manifest = protocol().manifest })
	end)
end

it("generates the exact All-audience KRF.Actions Map and three identity-only events through normal startup", function()
	expect(Server.Init({
		actions = {
			action("Action.Z", "ClientVisible"),
			action("Private.Secret", "ServerOnly"),
			action("Action.A", "ClientVisible"),
		},
	})).toBe(true)

	local domain: ReplicationTypes.LoadedReplicationDomainDefinition? = Domains.Get("KRF.Actions")
	expect(domain).never.toBeNil()
	assert(domain ~= nil, "N8 must generate the built-in Actions domain")
	expect(domain.audience).toBe("All")
	local state: SharedTypes.CompiledSchema = domain.state
	assert(state.kind == "Map", "Actions state must be sequenceId -> actionId")
	expect(state.maxEntries).toBe(256)
	expect(state.key.kind).toBe("U32")
	assert(state.value.kind == "Enum", "Action ids must use the visible startup Enum")
	expect(state.value.values).toEqual({ "Action.A", "Action.Z" })
	expect(state.value.ordinalsByValue["Private.Secret"]).toBeNil()
	local ids: { string } = {}

	for _, event: ReplicationTypes.LoadedReplicationEventDefinition in domain.events do
		table.insert(ids, event.id)
		local payload: SharedTypes.CompiledSchema = event.payload
		assert(payload.kind == "Struct", "Lifecycle payload must be bounded identity")
		expect(#payload.fields).toBe(2)
		expect(payload.fieldsByName.sequenceId.kind).toBe("U32")
		local enum: SharedTypes.CompiledSchema = payload.fieldsByName.actionId
		assert(enum.kind == "Enum", "Lifecycle ids must use the same visible catalog")
		expect(enum.values).toEqual(state.value.values)
	end

	table.sort(ids)
	expect(ids).toEqual({ "Ended", "Interrupted", "Started" })
	expect(protocol().runtime.domainsById["KRF.Actions"].id).toBe("KRF.Actions")
	local root: Instance? = ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME)
	assert(root ~= nil, "Expected installed native transport")
	local remotes: { string } = {}

	for _, child: Instance in root:GetChildren() do
		table.insert(remotes, child.Name .. ":" .. child.ClassName)
	end

	table.sort(remotes)
	expect(remotes).toEqual({ "Reliable:RemoteEvent", "Unreliable:UnreliableRemoteEvent" })
end)

it("keeps bootstrap bytes identical across declaration order and private Action implementation changes", function()
	expect(Server.Init({ actions = { action("Action.Z", "ClientVisible"), action("Action.A", "ClientVisible") } })).toBe(
		true
	)

	local previous: string = buffer.tostring(protocol().bootstrapBuffer)
	Server._ResetForTests()

	expect(Server.Init({
		actions = {
			function(): ActionTypes.ActionDefinition
				return {
					id = "Action.A",
					visibility = "ClientVisible",
					locks = { "Private.Lock" },
					interruptibleBy = { "Action.Z" },
					onStart = function() end,
				}
			end,
			action("Private.NeverSerialize", "ServerOnly"),
			action("Action.Z", "ClientVisible"),
		},
	})).toBe(true)

	expect(buffer.tostring(protocol().bootstrapBuffer)).toBe(previous)
	-- The equal-byte assertion alone could pass if Actions were omitted entirely.
	expect(#protocol().manifest.domains).toBe(1)
	expect(protocol().manifest.domains[1].id).toBe("KRF.Actions")
	expect(string.find(buffer.tostring(protocol().bootstrapBuffer), "Private.", 1, true)).toBeNil()
end)

for _, enabled: boolean in { false, true } do
	it("reserves KRF.Actions before catalog publication even when enabled=" .. tostring(enabled), function()
		local started: boolean, failure: Server.StartupFailure? = Server.Init({
			actions = if enabled then { action("Action.A", "ClientVisible") } else {},
			replicationDomains = { DomainUtils.createDomain("KRF.Actions") },
		})

		expect(started).toBe(false)
		expect(failure).toEqual({ system = "ReplicationDomain", reason = "DuplicateReplicationDomainId" })
		expect(Server._IsInitialized()).toBe(false)
		expect(Actions.IsLoaded()).toBe(false)
		expect(Domains.IsLoaded()).toBe(false)
		expect(Networking._IsInitialized()).toBe(false)
		expect(ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME)).toBeNil()
	end)
end
