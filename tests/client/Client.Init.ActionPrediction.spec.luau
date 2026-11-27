--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ClientTypes = require(KRF.client.types)
local Client: ClientTypes.Client = require(KRF.client)
local Types = require(KRF.client.Presentation.types)
local Events = require(KRF.client.Presentation.PresentationEvents)
local States = require(KRF.client.Presentation.PresentationStates)
local ClientUtils = require(script.Parent.Utils.ClientTestUtils)
local PredictionUtils = require(script.Parent.Utils.PresentationPredictionTestUtils)

afterEach(function()
	Client._ResetForTests()
end)

local function failure(config: ClientTypes.ClientInitConfig): ClientUtils.InitResult?
	Client._ResetForTests()
	local fixture: ClientUtils.Fixture = ClientUtils.new()
	ClientUtils.start(fixture, config)
	expect(fixture.order).toEqual({})

	return fixture.result
end

local function definition(entry: any, predict: any): any
	return { id = "Cast", entry = entry, predict = predict, create = function() end }
end

local fireball: Types.PresentationEntryBinding = { event = Events.Action.Started, id = "Fireball" }

it("starts normally with policies but no presentations, and with an omitted predict flag", function()
	local configs: { ClientTypes.ClientInitConfig } = {
		{ actionRequestSchemas = PredictionUtils.schemas, actionPredictionPolicies = { Fireball = {} } },
		{
			actionRequestSchemas = PredictionUtils.schemas,
			actionPredictionPolicies = {},
			presentations = {
				definition(fireball, nil),
				{ id = "Off", entry = fireball, predict = false, create = function() end },
			},
		},
	}

	for _, config: ClientTypes.ClientInitConfig in configs do
		Client._ResetForTests()
		local fixture: ClientUtils.Fixture = ClientUtils.new()
		ClientUtils.start(fixture, config)
		expect(fixture.result).toBeNil()
	end
end)

it("rejects policies for Actions outside the local request schema catalog before contacting the transport", function()
	expect(failure({ actionPredictionPolicies = { Fireball = {} } })).toEqual({
		success = false,
		failure = { system = "Presentation", reason = "ActionPredictionPolicyActionUnknown" },
	})

	expect(failure({ actionRequestSchemas = PredictionUtils.schemas, actionPredictionPolicies = { Unknown = {} } })).toEqual({
		success = false,
		failure = { system = "Presentation", reason = "ActionPredictionPolicyActionUnknown" },
	})
end)

it("fails startup when an opted-in definition has no policy for its Action", function()
	expect(failure({
		actionRequestSchemas = PredictionUtils.schemas,
		actionPredictionPolicies = { Dash = {} },
		presentations = { definition(fireball, true) },
	})).toEqual({
		success = false,
		failure = { system = "Presentation", reason = "PresentationPredictionPolicyMissing" },
	})
end)

it("rejects predict on any entry other than a live Action.Started event", function()
	local entries: { any } = {
		{ event = Events.Action.Ended, id = "Fireball" },
		{ event = Events.Tag.Added, id = "Fireball" },
		{ event = Events.Hint.Received, id = "Fireball" },
		{ state = States.Action.Active, id = "Fireball" },
	}

	for _, entry: any in entries do
		expect(failure({
			actionRequestSchemas = PredictionUtils.schemas,
			actionPredictionPolicies = { Fireball = {} },
			presentations = { definition(entry, true) },
		})).toEqual({
			success = false,
			failure = { system = "Presentation", reason = "PresentationPredictEntryInvalid" },
		})
	end

	expect(failure({
		actionRequestSchemas = PredictionUtils.schemas,
		actionPredictionPolicies = { Fireball = {} },
		presentations = { definition(fireball, "yes") },
	})).toEqual({ success = false, failure = { system = "Presentation", reason = "PresentationPredictInvalid" } })
end)

it("rejects LocalPrediction as a definition entry state", function()
	expect(failure({
		actionRequestSchemas = PredictionUtils.schemas,
		presentations = { definition({ state = States.Action.LocalPrediction, id = "Fireball" }, nil) },
	})).toEqual({ success = false, failure = { system = "Presentation", reason = "PresentationEntryStateInvalid" } })
end)

it("rolls back the whole configuration when a policy is malformed alongside valid definitions", function()
	local calls: number = 0

	expect(failure({
		actionRequestSchemas = PredictionUtils.schemas,
		actionPredictionPolicies = {
			Fireball = {
				costs = { Mana = -1 },
				canPredictStart = function(): boolean?
					calls += 1

					return true
				end,
			},
		},
		presentations = { definition(fireball, true) },
	})).toEqual({
		success = false,
		failure = { system = "Presentation", reason = "ActionPredictionPolicyCostInvalid" },
	})

	expect(calls).toBe(0)
end)
