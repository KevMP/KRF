--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local ClientTypes = require(KRF.client.types)
local Client: ClientTypes.Client = require(KRF.client)
local InputState = require(KRF.client.Input.utils.InputRuntimeState)
local ActionState = require(KRF.client.Action.utils.ClientActionRuntimeState)
local RequestState = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local ClientUtils = require(script.Parent.Utils.ClientTestUtils)
local Utils = require(script.Parent.Utils.ActionInputTestUtils)
local fixture: Utils.Fixture? = nil
local startup: ClientUtils.Fixture? = nil

afterEach(function()
	Utils.destroy(fixture)
	fixture = nil
	Client._ResetForTests()

	if startup ~= nil and startup.initThread ~= nil and coroutine.status(startup.initThread) ~= "dead" then
		coroutine.close(startup.initThread)
	end

	startup = nil
end)

local function refused(config: any, reason: string): ()
	Client._ResetForTests()
	local clientFixture: ClientUtils.Fixture = ClientUtils.new()
	startup = clientFixture
	ClientUtils.start(clientFixture, config)
	expect(clientFixture.result).toEqual({ success = false, failure = { system = "ActionInput", reason = reason } })
	expect(clientFixture.sent).toEqual({})
	expect(clientFixture.listening).toBe(false)
	expect(InputState.Get()).toBeNil()
	expect(ActionState.Get()).toBeNil()
	expect(RequestState.Get()).toBeNil()
end

it("keeps Client.Init without remote Action configuration compatible", function()
	Client._ResetForTests()
	startup = ClientUtils.new()
	ClientUtils.start(startup)
	ClientUtils.bootstrap(startup)
	ClientUtils.acknowledge(startup)
	expect(startup.result).toEqual({ success = true })
end)

it("accepts explicit compatible policies without executing either producer during initialization", function()
	fixture = Utils.new()
	local policies: Types.ActionInputPolicies = Utils.policies()
	local calls: number = 0

	policies["Combat.Rasengan"].startParameters = function(): any
		calls += 1
		error("Startup must not sample gameplay parameters", 0)
	end

	policies["Combat.Rasengan"].stopParameters = policies["Combat.Rasengan"].startParameters
	Utils.ready(fixture, policies)
	expect(calls).toBe(0)
	expect(fixture.commands.client.result).toEqual({ success = true })
end)

for _, policies: any in { false, 12, "WhileDown", function() end } do
	it("rejects a non-table policy catalog before handshake: " .. type(policies), function()
		refused(
			{ actionRequestSchemas = Utils.schemas(), actionInputPolicies = policies },
			"ActionInputPoliciesInvalid"
		)
	end)
end

local malformed: { { name: string, policy: any, reason: string } } = {
	{ name = "non-table entry", policy = false, reason = "ActionInputPolicyInvalid" },
	{ name = "unknown field", policy = { hold = true }, reason = "ActionInputPolicyFieldUnknown" },
	{ name = "route-owned activation", policy = { when = Utils.key() }, reason = "ActionInputPolicyFieldUnknown" },
	{ name = "invalid activation", policy = { activation = "Held" }, reason = "ActionInputActivationInvalid" },
	{ name = "non-string activation", policy = { activation = true }, reason = "ActionInputActivationInvalid" },
	{ name = "invalid invalidation", policy = { onInvalidation = "Stop" }, reason = "ActionInputInvalidationInvalid" },
	{ name = "invalid Start producer", policy = { startParameters = {} }, reason = "ActionInputProducerInvalid" },
	{ name = "invalid Stop producer", policy = { stopParameters = true }, reason = "ActionInputProducerInvalid" },
	{ name = "metatable entry", policy = setmetatable({}, {}), reason = "ActionInputPolicyInvalid" },
}

for _, case in malformed do
	it("rejects " .. case.name .. " atomically with a stable reason", function()
		local config: any = {
			actionRequestSchemas = { ["Mode.Aura"] = { stop = {}, allowInputInterrupt = true } },
			actionInputPolicies = { ["Mode.Aura"] = case.policy },
		}

		refused(config, case.reason)
		refused(config, case.reason)
	end)
end

it("rejects a policy for an Action absent from the shared wire catalog", function()
	refused(
		{ actionRequestSchemas = {}, actionInputPolicies = { ["Game.Missing"] = {} } },
		"ActionInputPolicyUnknownAction"
	)
end)

it("rejects policies without a shared wire catalog rather than creating a second registry", function()
	refused({ actionInputPolicies = { ["Mode.Aura"] = {} } }, "ActionInputPolicyUnknownAction")
end)

for _, policy: any in { "Omitted", {}, { activation = "OneShot" }, { activation = "Toggle" } } do
	it("requires explicit WhileDown for requiresClientRelease, policy=" .. tostring(policy), function()
		local policies: any = Utils.policies()
		policies["Combat.Rasengan"] = if policy == "Omitted" then nil else policy

		refused(
			{ actionRequestSchemas = Utils.schemas(), actionInputPolicies = policies },
			"ActionInputReleasePolicyRequired"
		)
	end)
end

for _, activation: "WhileDown" | "Toggle" in { "WhileDown", "Toggle" } do
	it("requires a declared Stop for " .. activation .. " even with Interrupt permission", function()
		refused({
			actionRequestSchemas = { ["Mode.Aura"] = { allowInputInterrupt = true } },
			actionInputPolicies = { ["Mode.Aura"] = { activation = activation } },
		}, "ActionInputStopRequired")
	end)
end

it("requires a producer when the automatic Stop schema cannot encode nil", function()
	local policies: Types.ActionInputPolicies = Utils.policies()
	policies["Combat.Rasengan"].stopParameters = nil

	refused(
		{ actionRequestSchemas = Utils.schemas(), actionInputPolicies = policies },
		"ActionInputStopProducerRequired"
	)
end)

it("requires Interrupt permission for a Stop producer even with explicit Keep invalidation", function()
	local schemas = Utils.schemas()
	schemas["Combat.Rasengan"].allowInputInterrupt = false

	local policies: Types.ActionInputPolicies = Utils.policies()
	policies["Combat.Rasengan"].onInvalidation = "Keep"
	refused({ actionRequestSchemas = schemas, actionInputPolicies = policies }, "ActionInputInterruptRequired")
end)

for _, activation: "WhileDown" | "Toggle" in { "WhileDown", "Toggle" } do
	it("requires permission for " .. activation .. " Interrupt invalidation", function()
		refused({
			actionRequestSchemas = { ["Mode.Aura"] = { stop = {} } },
			actionInputPolicies = { ["Mode.Aura"] = { activation = activation, onInvalidation = "Interrupt" } },
		}, "ActionInputInterruptRequired")
	end)
end

it("requires permission for the default WhileDown Interrupt invalidation", function()
	refused({
		actionRequestSchemas = { ["Mode.Aura"] = { stop = {} } },
		actionInputPolicies = { ["Mode.Aura"] = { activation = "WhileDown" } },
	}, "ActionInputInterruptRequired")
end)

for _, activation: "WhileDown" | "Toggle" in { "WhileDown", "Toggle" } do
	it("allows deliberate Keep and parameterless Stop without an automatic producer: " .. activation, function()
		fixture = Utils.new()

		Utils.ready(
			fixture,
			{ ["Mode.Aura"] = { activation = activation, onInvalidation = "Keep" } },
			{ ["Mode.Aura"] = { stop = {} } }
		)

		expect(fixture.commands.client.result).toEqual({ success = true })
	end)
end

it("rejects cyclic policy input without traversing or invoking it", function()
	local policy: any = {}
	policy.activation = policy

	refused(
		{ actionRequestSchemas = { ["Mode.Aura"] = {} }, actionInputPolicies = { ["Mode.Aura"] = policy } },
		"ActionInputActivationInvalid"
	)
end)

it("rejects an overlarge policy catalog before owner publication", function()
	local schemas: any = {}
	local policies: any = {}

	for index: number = 1, 4097 do
		local actionId: string = "Game.Action" .. index

		schemas[actionId] = {}
		policies[actionId] = {}
	end

	refused({ actionRequestSchemas = schemas, actionInputPolicies = policies }, "ActionInputPolicyLimitExceeded")
end)
