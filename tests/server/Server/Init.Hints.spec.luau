--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Server = require(KRF.server)
local ServerTypes = require(KRF.server.types)
local Types = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Networking: Types.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Codec: SharedTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local Transport = require(KRF.shared.Networking.Transport)
local Domains = require(KRF.server.Replication.ReplicationDomainRegistry)
local Commands = require(KRF.server.Networking.CommandRegistry)
local Registry: Types.HintRegistry = require(KRF.server.Networking.HintRegistry)
local HintConstants = require(KRF.shared.Networking.utils.HintConstants)
local SchemaCompiler = require(KRF.shared.Networking.utils.SchemaCompiler)
local originalPublish: typeof(Networking.Publish) = Networking.Publish
local prepared: SharedTypes.PreparedProtocol?

beforeEach(function()
	Server._ResetForTests()
	prepared = nil

	Networking.Publish = function(protocol: SharedTypes.PreparedProtocol): (boolean, string?)
		prepared = protocol

		return originalPublish(protocol)
	end
end)

afterEach(function()
	Networking.Publish = originalPublish
	Server._ResetForTests()
end)

local function definition(id: string): Types.HintDefinition
	return { id = id, direction = "ServerToClient", target = "None", mode = "Pulse", payload = Schema.U8 }
end

local function start(definitions: { Types.HintDefinition }?): SharedTypes.PreparedProtocol
	local success, failure = Server.Init({ hints = definitions })
	expect(success).toBe(true)
	expect(failure).toBeNil()
	assert(prepared ~= nil, "Expected actual startup protocol preparation")

	return prepared
end

it("starts omitted and explicitly empty Hint catalogs with compiled empty codebooks", function()
	local configs: { ServerTypes.ServerStartConfig } = { {}, { hints = {} } }

	for _, config in configs do
		Server._ResetForTests()
		local success, failure = Server.Init(config)
		expect(success).toBe(true)
		expect(failure).toBeNil()
		local protocol = prepared
		assert(protocol ~= nil, "Expected startup protocol")
		expect(protocol.runtime.hintsById).toEqual({})
		expect(protocol.runtime.hintsByCode).toEqual({})
	end
end)

for _, direction in { "ClientToServer", "ServerToClient" } do
	for _, target in { "None", "Actor" } do
		for _, mode in { "Latest", "Pulse" } do
			it("bootstraps " .. direction .. " " .. target .. " " .. mode .. " without invoking callbacks", function()
				local hint: any = definition("Game.Look")
				hint.direction, hint.target, hint.mode = direction, target, mode
				hint.payload = Schema.Struct({ direction = Schema.Enum({ "Left", "Right" }) })

				local calls = 0

				if direction == "ClientToServer" then
					hint.authorize = function(): (boolean, string?)
						calls += 1

						return true, nil
					end

					hint.receive = function(): ()
						calls += 1
					end
				end

				local protocol = start({ hint })
				local decoded, reason = Codec.Decode(protocol.bootstrapBuffer)
				expect(reason).toBeNil()
				assert(decoded ~= nil and decoded.kind == "Bootstrap", "Expected bootstrap")

				expect(decoded.manifest.hints).toEqual({
					{
						id = "Game.Look",
						code = 0,
						direction = direction,
						target = target,
						mode = mode,
						payload = {
							kind = "Struct",
							fields = { direction = { kind = "Enum", values = { "Left", "Right" } } },
						},
					},
				})

				assert(protocol.runtime.hintsById ~= nil, "Expected compiled Hint codebook")
				local installed = protocol.runtime.hintsById["Game.Look"]
				expect(installed.payloadCodec.Measure({ direction = "Right" })).toBe(1)
				expect(calls).toBe(0)
			end)
		end
	end
end

it("assigns identical compact Hint codes and bootstrap bytes regardless of declaration order", function()
	local first, second = definition("Game.Zeta"), definition("KRF.Presentation")
	local forward = start({ first, second })
	Server._ResetForTests()
	local reverse = start({ second, first })
	expect(reverse.manifest).toEqual(forward.manifest)
	expect(buffer.tostring(reverse.bootstrapBuffer)).toBe(buffer.tostring(forward.bootstrapBuffer))
	assert(forward.runtime.hintsById ~= nil, "Expected Hint codebook")
	expect(forward.runtime.hintsById["Game.Zeta"].code).toBe(0)
	expect(forward.runtime.hintsById["KRF.Presentation"].code).toBe(1)
end)

it("owns immutable Hint definitions, schemas and codebooks independently of author mutation", function()
	local fields = { count = Schema.U16 }

	local hint = definition("Game.Cosmetic")
	hint.payload = { kind = "Struct", fields = fields }

	local protocol = start({ hint })

	hint.id, hint.target, hint.mode = "Game.Mutated", "Actor", "Latest"
	fields.count = Schema.String(100)

	assert(
		protocol.manifest.hints ~= nil and protocol.runtime.hintsById ~= nil and protocol.runtime.hintsByCode ~= nil,
		"Expected Hint metadata"
	)

	local projected = protocol.manifest.hints[1]
	local installed = protocol.runtime.hintsById["Game.Cosmetic"]
	expect(projected.id).toBe("Game.Cosmetic")
	expect(projected.target).toBe("None")
	expect(projected.mode).toBe("Pulse")
	expect(installed.payloadCodec.Measure({ count = 65535 })).toBe(2)
	expect(table.isfrozen(projected.payload)).toBe(true)
	expect(table.isfrozen(projected)).toBe(true)
	expect(table.isfrozen(protocol.manifest.hints)).toBe(true)
	expect(table.isfrozen(installed)).toBe(true)
	expect(table.isfrozen(protocol.runtime.hintsById)).toBe(true)
	expect(table.isfrozen(protocol.runtime.hintsByCode)).toBe(true)
end)

for _, invalid: any in
	{
		{ label = "missing id", field = "id", reason = "HintIdInvalid" },
		{ label = "empty id", field = "id", value = "", reason = "HintIdInvalid" },
		{ label = "unknown direction", field = "direction", value = "Both", reason = "HintDirectionInvalid" },
		{ label = "missing direction", field = "direction", reason = "HintDirectionInvalid" },
		{ label = "unknown target", field = "target", value = "Player", reason = "HintTargetInvalid" },
		{ label = "missing target", field = "target", reason = "HintTargetInvalid" },
		{ label = "unknown mode", field = "mode", value = "Reliable", reason = "HintModeInvalid" },
		{ label = "missing mode", field = "mode", reason = "HintModeInvalid" },
		{ label = "missing payload", field = "payload" },
		{ label = "unbounded payload", field = "payload", value = { kind = "String" } },
		{ label = "oversized record", field = "payload", value = Schema.String(1000), reason = "HintRecordTooLarge" },
		{ label = "unknown field", field = "handler", value = true, reason = "HintFieldUnknown" },
	}
do
	it("rejects " .. invalid.label .. " before publishing startup catalogs or transports", function()
		local hint: any = definition("Game.Invalid")
		hint[invalid.field] = invalid.value
		local success: boolean, failure: ServerTypes.StartupFailure? = Server.Init({ hints = { hint } })
		expect(success).toBe(false)
		assert(failure ~= nil, "Expected invalid Hint startup failure")
		expect(failure.system).toBe("Hint")

		if invalid.reason ~= nil then
			expect(failure.reason).toBe(invalid.reason)
		else
			expect(type(failure.reason)).toBe("string")
		end

		expect(Domains.IsLoaded()).toBe(false)
		expect(Commands.IsLoaded()).toBe(false)
		expect(Networking._IsInitialized()).toBe(false)
		expect(ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME)).toBeNil()
	end)
end

it("publishes a frozen lookup facade once and rejects catalog replacement outside startup", function()
	expect(Registry.IsLoaded()).toBe(false)
	expect(Registry.GetAll()).toEqual({})
	expect(Registry.Get("Game.Missing")).toBeNil()
	local catalog = assert(Registry.Prepare({ definition("Game.Registered") }))
	local published, reason = Registry.Publish(catalog)
	expect(published).toBe(true)
	expect(reason).toBeNil()
	expect(Registry.GetAll()).toBe(catalog.orderedDefinitions)
	expect(Registry.Get("Game.Registered")).toBe(catalog.definitionsById["Game.Registered"])
	expect(table.isfrozen(Registry)).toBe(true)
	expect(table.isfrozen(catalog)).toBe(true)
	expect(table.isfrozen(catalog.definitionsById)).toBe(true)
	local repeated, prepareReason = Registry.Prepare({})
	expect(repeated).toBeNil()
	expect(prepareReason).toBe("HintDefinitionsAlreadyLoaded")
	published, reason = Registry.Publish(catalog)
	expect(published).toBe(false)
	expect(reason).toBe("HintDefinitionsAlreadyLoaded")
	local success, failure = Server.Init({})
	expect(success).toBe(false)
	expect(failure).toEqual({ system = "Server", reason = "CatalogAlreadyLoaded" })
	expect(Registry.GetAll()).toBe(catalog.orderedDefinitions)
end)

it("rolls back the Hint catalog with other registries when transport publication fails", function()
	local loadedDuringPublish = false

	Networking.Publish = function(): (boolean, string?)
		loadedDuringPublish = Registry.IsLoaded() and Registry.Get("Game.Rollback") ~= nil

		return false, "TransportConflict"
	end

	local success, failure = Server.Init({ hints = { definition("Game.Rollback") } })
	expect(success).toBe(false)
	expect(failure).toEqual({ system = "Networking", reason = "TransportConflict" })
	expect(loadedDuringPublish).toBe(true)
	expect(Registry.IsLoaded()).toBe(false)
	expect(Registry.Get("Game.Rollback")).toBeNil()
	expect(Registry.GetAll()).toEqual({})
	expect(Commands.IsLoaded()).toBe(false)
	expect(Domains.IsLoaded()).toBe(false)
	expect(ReplicatedStorage:FindFirstChild(Transport.ROOT_NAME)).toBeNil()
end)

it("retains server callback references independently of author changes without invoking them", function()
	local hint = definition("Game.Input")
	hint.direction = "ClientToServer"

	hint.authorize = function(): (boolean, string?)
		return true, nil
	end

	hint.receive = function(): () end
	local authorize, receive = hint.authorize, hint.receive
	start({ hint })
	hint.authorize = nil
	hint.receive = nil

	local loaded = assert(Registry.Get("Game.Input"))
	expect(loaded.authorize).toBe(authorize)
	expect(loaded.receive).toBe(receive)
	expect(table.isfrozen(loaded)).toBe(true)
end)

it("bounds startup Hint count and rejects non-string fields", function()
	local oversized = table.create(HintConstants.MAX_HINTS + 1, definition("Game.Limit"))
	local catalog, reason = Registry.Prepare(oversized)
	expect(catalog).toBeNil()
	expect(reason).toBe("HintDefinitionsMustBeBoundedArray")

	local invalid: any = definition("Game.Invalid")
	invalid[1] = true
	catalog, reason = Registry.Prepare({ invalid })
	expect(catalog).toBeNil()
	expect(reason).toBe("HintFieldUnknown")
	expect(Registry.IsLoaded()).toBe(false)
end)

for _, target: SharedTypes.HintTarget in { "None", "Actor" } do
	for _, mode: SharedTypes.HintMode in { "Latest", "Pulse" } do
		it("applies full conservative packet admission at startup for " .. target .. " " .. mode, function()
			local minimum = assert(SchemaCompiler.Compile(Schema.String(1)))

			local maximumString = HintConstants.MAX_PACKET_BYTES
				- HintConstants.PACKET_HEADER_BYTES
				- HintConstants.RecordBytes(minimum.maxEncodedBytes - 1, target, mode)

			for _, extra in { -1, 0, 1 } do
				local hint = definition("Game.Boundary")
				hint.target, hint.mode, hint.payload = target, mode, Schema.String(maximumString + extra)
				local catalog, reason = Registry.Prepare({ hint })
				expect(Registry.IsLoaded()).toBe(false)

				if extra == 1 then
					expect(catalog).toBeNil()
					expect(reason).toBe("HintRecordTooLarge")
				else
					expect(catalog ~= nil).toBe(true)
					expect(reason).toBeNil()
				end
			end
		end)
	end
end

for _, field in { "authorize", "receive" } do
	for _, value in { false, "OwnerActor" } do
		it("requires a ClientToServer " .. field .. " callback instead of " .. tostring(value), function()
			local hint: any = definition("Game.Input")
			hint.direction = "ClientToServer"

			hint.authorize = function(): (boolean, string?)
				return true, nil
			end

			hint.receive = function(): () end
			hint[field] = if value == false then nil else value
			local success, failure = Server.Init({ hints = { hint } })
			expect(success).toBe(false)

			expect(failure).toEqual({
				system = "Hint",
				reason = if field == "authorize" then "HintAuthorizationRequired" else "HintReceiverRequired",
			})
		end)
	end
end

it("rejects duplicate Hint ids across framework and game definitions", function()
	local success, failure = Server.Init({ hints = { definition("KRF.Look"), definition("KRF.Look") } })
	expect(success).toBe(false)
	expect(failure).toEqual({ system = "Hint", reason = "DuplicateHintId" })
end)

for _, invalid: any in
	{
		{ value = false, reason = "HintDefinitionsMustBeTable" },
		{ value = { [2] = definition("Game.Sparse") }, reason = "HintDefinitionsMustBeBoundedArray" },
		{ value = { false }, reason = "HintDefinitionMustBeTable" },
	}
do
	it("rejects " .. invalid.reason .. " transactionally", function()
		local success, failure = Server.Init({ hints = invalid.value })
		expect(success).toBe(false)
		expect(failure).toEqual({ system = "Hint", reason = invalid.reason })
	end)
end
