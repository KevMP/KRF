--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.ActionRequest.types)
local NetworkingTypes = require(KRF.client.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Constants = require(KRF.shared.ActionRequest.utils.ActionRequestConstants)
local Envelopes = require(KRF.shared.ActionRequest.utils.ActionCommandEnvelopes)
local CommandManifest = require(KRF.shared.Networking.utils.CommandManifest)
local CommandState = require(KRF.client.Networking.utils.CommandRuntimeState)
local State = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local Installation = require(KRF.client.ActionRequest.utils.ClientActionRequestInstallation)
local RequestUtils = require(script.Parent.Parent.shared.Utils.ActionRequestTestUtils)

afterEach(function()
	CommandState.Install(nil)
	State.Install(nil)
end)

type Override = {
	missing: boolean?,
	target: ("None" | "Actor")?,
	request: SharedTypes.SchemaDefinition?,
	result: SharedTypes.SchemaDefinition?,
}

-- Only the private seams the installation adapts; nothing is sent in these tests.
local function commands(classified: { { string } }?): NetworkingTypes.ClientCommandRuntime
	local fake: any = {
		_SendAdmitted = function(): (number?, string?)
			return nil, "Unused"
		end,
		_ObserveOutcomes = function(): () -> ()
			return function(): () end
		end,
		_ObserveCapacity = function(): () -> ()
			return function(): () end
		end,
		_AfterEgress = function(_self: NetworkingTypes.ClientCommandRuntime, callback: () -> ()): ()
			callback()
		end,
		_ClassifyFollowUps = function(_self: any, commandIds: { string }): (boolean, string?)
			if classified ~= nil then
				table.insert(classified, table.clone(commandIds))
			end

			return true, nil
		end,
	}

	return fake
end

-- Reconstructs the fixed commands through the real manifest compiler, as the bootstrap does.
local function protocol(overrides: { [string]: Override }?): SharedTypes.ClientProtocol
	local manifest: { SharedTypes.ManifestCommand } = {}

	for _, envelope: Envelopes.ActionCommandEnvelope in Envelopes.All do
		local override: Override = if overrides ~= nil then overrides[envelope.id] or {} else {}

		if not override.missing then
			table.insert(manifest, {
				id = envelope.id,
				code = #manifest,
				target = override.target or envelope.target,
				request = override.request or envelope.request,
				result = override.result or envelope.result,
			})
		end
	end

	local byId: { [string]: SharedTypes.ClientCommand }?, byCode: { [number]: SharedTypes.ClientCommand }?, reason: string? =
		CommandManifest.Compile(manifest)

	assert(byId ~= nil, reason)

	local reconstructed: any = { commandsById = byId, commandsByCode = byCode }

	return reconstructed
end

local function install(source: SharedTypes.ClientProtocol): ((() -> ())?, string?)
	return Installation.Install(RequestUtils.catalog(RequestUtils.schemas()), source)
end

for _, case in
	{
		{ label = "a missing Stop command", overrides = { [Constants.STOP_COMMAND_ID] = { missing = true } } },
		{
			label = "a Start command without an Actor target",
			overrides = { [Constants.START_COMMAND_ID] = { target = "None" } },
		},
	} :: { { label: string, overrides: { [string]: Override } } }
do
	it("refuses " .. case.label .. " without installing a runtime", function()
		CommandState.Install(commands())
		local cleanup: (() -> ())?, reason: string? = install(protocol(case.overrides))
		expect(cleanup).toBeNil()
		expect(reason).toBe("ActionRequestCommandsUnavailable")
		expect(State.Get()).toBeNil()
	end)
end

for _, case in
	{
		{
			label = "a Start request with a different payload bound",
			overrides = {
				[Constants.START_COMMAND_ID] = {
					request = Schema.Struct({
						actionId = Schema.String(Constants.MAX_ACTION_ID_BYTES),
						contractTag = Schema.U32,
						payload = Schema.String(16),
					}),
				},
			},
		},
		{
			label = "a Start result without a sequence ID",
			overrides = { [Constants.START_COMMAND_ID] = { result = Schema.Struct({ accepted = Schema.Boolean }) } },
		},
		{
			label = "a Stop request with a renamed receipt field",
			overrides = {
				[Constants.STOP_COMMAND_ID] = {
					request = Schema.Struct({
						originalRequestId = Schema.U32,
						payload = Schema.String(Constants.MAX_PAYLOAD_BYTES),
					}),
				},
			},
		},
		{
			label = "an Interrupt with a different reason Enum",
			overrides = {
				[Constants.INTERRUPT_COMMAND_ID] = {
					request = Schema.Struct({
						originalStartRequestId = Schema.U32,
						reason = Schema.Enum({ "FocusLost" }),
					}),
				},
			},
		},
		{
			label = "a Stop that unexpectedly returns a result",
			overrides = { [Constants.STOP_COMMAND_ID] = { result = Schema.U32 } },
		},
	} :: { { label: string, overrides: { [string]: Override } } }
do
	it("refuses correctly named commands with " .. case.label, function()
		local classified: { { string } } = {}
		CommandState.Install(commands(classified))
		local cleanup: (() -> ())?, reason: string? = install(protocol(case.overrides))
		expect(cleanup).toBeNil()
		expect(reason).toBe("ActionRequestCommandsIncompatible")
		expect(State.Get()).toBeNil()
		expect(classified).toEqual({})
	end)
end

it("classifies Stop and Interrupt as protected follow-ups only while installed", function()
	local classified: { { string } } = {}
	CommandState.Install(commands(classified))
	local cleanup: (() -> ())? = install(protocol())
	assert(cleanup ~= nil, "Expected an installation")
	expect(classified).toEqual({ { Constants.STOP_COMMAND_ID, Constants.INTERRUPT_COMMAND_ID } })

	cleanup()
	cleanup()
	expect(classified).toEqual({ { Constants.STOP_COMMAND_ID, Constants.INTERRUPT_COMMAND_ID }, {} })
end)

it("refuses when no command runtime is installed", function()
	local cleanup: (() -> ())?, reason: string? = install(protocol())
	expect(cleanup).toBeNil()
	expect(reason).toBe("ActionRequestCommandsUnavailable")
end)

it("installs a new incarnation each time and never lets a stale cleanup remove a newer runtime", function()
	CommandState.Install(commands())
	local first: (() -> ())? = install(protocol())
	assert(first ~= nil, "Expected the first installation")
	local firstRuntime: Types.ClientActionRequestRuntime? = State.Get()
	local second: (() -> ())? = install(protocol())
	assert(second ~= nil, "Expected the second installation")
	local secondRuntime: Types.ClientActionRequestRuntime? = State.Get()
	expect(secondRuntime).never.toBe(firstRuntime)

	first()
	first()
	expect(State.Get()).toBe(secondRuntime)
	second()
	expect(State.Get()).toBeNil()
end)

it("refuses when the command runtime cannot classify the follow-ups", function()
	local refusing: any = commands()

	refusing._ClassifyFollowUps = function(): (boolean, string?)
		return false, "UnknownCommand"
	end

	CommandState.Install(refusing)
	local cleanup: (() -> ())?, reason: string? = install(protocol())
	expect(cleanup).toBeNil()
	expect(reason).toBe("ActionRequestCommandsUnavailable")
	expect(State.Get()).toBeNil()
end)
