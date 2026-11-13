--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.ActionRequest.types)
local Runtime: Types.ClientActionRequestRuntimeModule = require(KRF.client.ActionRequest.ClientActionRequestRuntime)
local Constants = require(KRF.shared.ActionRequest.utils.ActionRequestConstants)
local Utils = require(script.Parent.Utils.ActionRequestClientTestUtils)
local fixture: Utils.Fixture?

afterEach(function()
	Utils.destroy(fixture)
	fixture = nil
end)

it("admits requests and delivers outcomes without optional capacity or expiration hooks", function()
	local created: Utils.Fixture = Utils.new()
	fixture = created
	created.runtime:Destroy()

	local commands: Types.ActionRequestCommandPort = {
		SendAdmitted = created.port.port.SendAdmitted,
		ObserveOutcomes = created.port.port.ObserveOutcomes,
	}

	created.runtime = Runtime.new(created.catalog, { commands = commands, incarnation = 2 })

	local outcomes: { Types.ActionRequestOutcome } = {}

	created.runtime:ObserveOutcomes(function(outcome: Types.ActionRequestOutcome): ()
		table.insert(outcomes, outcome)
	end)

	expect({ created.runtime:Start(Utils.selection(created, "Movement.Sprint")) }).toEqual({ 1 })
	expect({ created.runtime:Stop(1) }).toEqual({ 2 })
	Utils.deliver(created, 2, Constants.STOP_COMMAND_ID, "Accepted")
	expect(#outcomes).toBe(1)
	expect(outcomes[1]).toMatchObject({ status = "Accepted", admission = { requestId = 2, kind = "Stop" } })
	created.runtime:Destroy()
	expect(created.port.observers).toEqual({})
	expect(created.runtime:_GetRetainedCountForTests()).toBe(0)
end)

for _, failurePoint: string in { "Capacity", "Expirations" } do
	it("removes earlier subscriptions when the " .. failurePoint .. " subscription fails", function()
		local created: Utils.Fixture = Utils.new()
		fixture = created
		created.runtime:Destroy()

		local commands: Types.ActionRequestCommandPort = {
			SendAdmitted = created.port.port.SendAdmitted,
			ObserveOutcomes = created.port.port.ObserveOutcomes,
			ObserveCapacity = function(observer: () -> ()): () -> ()
				if failurePoint == "Capacity" then
					error("SubscriptionSetupFailed", 0)
				end

				return assert(created.port.port.ObserveCapacity, "Expected capacity subscription")(observer)
			end,
			ObserveExpirations = function(_observer: (number, string) -> ()): () -> ()
				error("SubscriptionSetupFailed", 0)
			end,
		}

		expect(function()
			created.runtime = Runtime.new(created.catalog, { commands = commands, incarnation = 2 })
		end).toThrow("SubscriptionSetupFailed")

		expect(created.port.observers).toEqual({})
		expect(created.port.capacityObservers).toEqual({})
		expect(created.port.sent).toEqual({})
	end)
end
