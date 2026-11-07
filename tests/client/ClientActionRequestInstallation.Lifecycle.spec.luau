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
local Constants = require(KRF.shared.ActionRequest.utils.ActionRequestConstants)
local CommandState = require(KRF.client.Networking.utils.CommandRuntimeState)
local State = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local Installation = require(KRF.client.ActionRequest.utils.ClientActionRequestInstallation)
local RequestUtils = require(script.Parent.Parent.shared.Utils.ActionRequestTestUtils)

afterEach(function()
	CommandState.Install(nil)
	State.Install(nil)
end)

-- Only the private seams the installation adapts; nothing is sent in these tests.
local function commands(): NetworkingTypes.ClientCommandRuntime
	local fake: any = {
		_SendAdmitted = function(): (number?, string?)
			return nil, "Unused"
		end,
		_ObserveOutcomes = function(): () -> ()
			return function(): () end
		end,
	}

	return fake
end

local function protocol(overrides: { [string]: "None" | "Actor" | false }?): SharedTypes.ClientProtocol
	local byId: { [string]: any } = {
		[Constants.START_COMMAND_ID] = { id = Constants.START_COMMAND_ID, code = 0, target = "Actor" },
		[Constants.STOP_COMMAND_ID] = { id = Constants.STOP_COMMAND_ID, code = 1, target = "None" },
		[Constants.INTERRUPT_COMMAND_ID] = { id = Constants.INTERRUPT_COMMAND_ID, code = 2, target = "None" },
	}

	for commandId: string, target: "None" | "Actor" | false in overrides or {} do
		byId[commandId] = if target == false then nil else { id = commandId, code = 9, target = target }
	end

	local reconstructed: any = { commandsById = byId }

	return reconstructed
end

local function install(source: SharedTypes.ClientProtocol): ((() -> ())?, string?)
	return Installation.Install(RequestUtils.catalog(RequestUtils.schemas()), source)
end

for _, case in
	{
		{ label = "a missing Stop command", overrides = { [Constants.STOP_COMMAND_ID] = false } },
		{ label = "a Start command without an Actor target", overrides = { [Constants.START_COMMAND_ID] = "None" } },
	} :: { { label: string, overrides: { [string]: "None" | "Actor" | false } } }
do
	it("refuses " .. case.label .. " without installing a runtime", function()
		CommandState.Install(commands())
		local cleanup: (() -> ())?, reason: string? = install(protocol(case.overrides))
		expect(cleanup).toBeNil()
		expect(reason).toBe("ActionRequestCommandsUnavailable")
		expect(State.Get()).toBeNil()
	end)
end

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
