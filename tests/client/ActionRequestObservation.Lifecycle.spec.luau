--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local RequestTypes = require(KRF.client.ActionRequest.types)
local Observation = require(KRF.client.Action.utils.ActionRequestObservation)
local Installation = require(KRF.client.Action.utils.ActionObservationInstallation)
local RequestState = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Utils = require(script.Parent.Utils.ActionRequestClientTestUtils)
local fixture: Utils.Fixture?
local owner: Types.ActionObservationOwner?

afterEach(function()
	if owner ~= nil then
		owner.Destroy()
	end

	owner = nil
	Utils.destroy(fixture)
	fixture = nil
	RequestState.Install(nil)
end)

local function options(
	created: Utils.Fixture,
	facts: { Types.ActionRequestEvent },
	reports: { string }
): Observation.Options
	return {
		Requests = created.runtime,
		Now = function(): number
			return 120
		end,
		Publish = function(fact: Types.ActionRequestEvent): ()
			table.insert(facts, fact)
		end,
		Report = function(reason: string): ()
			table.insert(reports, reason)
		end,
	}
end

it("fences a replaced installation and prevents its late cleanup from clearing the new observer generation", function()
	local created: Utils.Fixture = Utils.new()
	fixture = created
	RequestState.Install(created.runtime)

	local stopPrevious = Installation.Install(function(): number
		return 120
	end)

	local oldCalls: number = 0

	State.ObserveActionRequest(function(): ()
		oldCalls += 1
	end)

	local stopCurrent = Installation.Install(function(): number
		return 130
	end)

	local newCalls: number = 0

	State.ObserveActionRequest(function(): ()
		newCalls += 1
	end)

	local publicCalls: number = 0

	local connection = State.OnActionRequest:Connect(function(): ()
		publicCalls += 1
	end)

	stopPrevious()
	assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))
	task.wait()
	connection:Disconnect()
	stopCurrent()
	expect(oldCalls).toBe(0)
	expect(newCalls).toBe(1)
	expect(publicCalls).toBe(1)
end)

it("disposes an installation once and leaves late state subscriptions and ordinal injection inert", function()
	local created: Utils.Fixture = Utils.new()
	fixture = created
	RequestState.Install(created.runtime)

	local stop = Installation.Install(function(): number
		return 120
	end)

	local calls: number = 0

	local disconnect = State.ObserveActionRequest(function(): ()
		calls += 1
	end)

	assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))
	stop()
	stop()
	State._SetObservationOrdinalForTests(20)

	State.ObserveActionRequest(function(): ()
		calls += 1
	end)()

	assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))
	disconnect()
	expect(calls).toBe(1)
	expect(#created.port.sent).toBe(2)
end)

it("honors disconnection during dispatch and drops publication if the private owner tears down", function()
	local created: Utils.Fixture = Utils.new()
	fixture = created
	local facts: { Types.ActionRequestEvent } = {}
	local observation: Types.ActionObservationOwner = Observation.new(options(created, facts, {}))
	owner = observation
	local calls: number = 0
	local stopLater: (() -> ())?

	observation.Observe(function(): ()
		assert(stopLater, "Expected later subscriber")()
	end)

	stopLater = observation.Observe(function(): ()
		calls += 1
	end)

	assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))
	expect(calls).toBe(0)
	expect(#facts).toBe(1)

	observation.Observe(function(): ()
		observation.Destroy()
	end)

	assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))
	expect(#facts).toBe(1)
	expect(#created.port.sent).toBe(2)
end)

for _, stream: string in { "Admissions", "Outcomes" } do
	it("rolls back subscriptions when the " .. stream .. " observer bound rejects installation", function()
		local created: Utils.Fixture = Utils.new()
		fixture = created

		for _ = 1, 16 do
			if stream == "Admissions" then
				created.runtime:ObserveAdmissions(function(): () end)
			else
				created.runtime:ObserveOutcomes(function(): () end)
			end
		end

		expect(function(): ()
			owner = Observation.new(options(created, {}, {}))
		end).toThrow("ActionRequestObserverLimitExceeded")

		if stream == "Outcomes" then
			for _ = 1, 16 do
				created.runtime:ObserveAdmissions(function(): () end)
			end
		else
			for _ = 1, 16 do
				created.runtime:ObserveOutcomes(function(): () end)
			end
		end
	end)
end

it("quarantines over-budget private work once while preserving publication and subsequent requests", function()
	local created: Utils.Fixture = Utils.new()
	fixture = created
	local facts: { Types.ActionRequestEvent } = {}
	local reports: { string } = {}
	local workClock: number = 0

	local configuration: Observation.Options = options(created, facts, reports)

	configuration.Measure = function(): number
		return workClock
	end

	local observation: Types.ActionObservationOwner = Observation.new(configuration)
	owner = observation
	local calls: number = 0

	observation.Observe(function(): ()
		calls += 1
		workClock += 0.003
	end)

	assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))
	assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))
	expect(calls).toBe(1)
	expect(reports).toEqual({ "ActionObservationObserverOverBudget" })
	expect(#created.port.sent).toBe(2)
	expect(#facts).toBe(2)
end)

it("diagnoses malformed Accepted Start once without publishing a fact with a missing sequence", function()
	local created: Utils.Fixture = Utils.new()
	fixture = created
	local facts: { Types.ActionRequestEvent } = {}
	local reports: { string } = {}
	owner = Observation.new(options(created, facts, reports))

	for index = 1, 2 do
		assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))
		Utils.deliver(created, index, "KRF.Action.Start", "Accepted")
	end

	expect(#facts).toBe(2)
	expect(reports).toEqual({ "ActionObservationSequenceMissing" })
	expect(facts[2].eventOrdinal).toBe(2)
end)

it("fences captured callbacks after destruction and makes repeated cleanup and late subscriptions inert", function()
	local created: Utils.Fixture = Utils.new()
	fixture = created
	local captured: ((RequestTypes.ActionRequestAdmission) -> ())?
	local subscribe = created.runtime.ObserveAdmissions

	created.runtime.ObserveAdmissions = function(self, callback): () -> ()
		captured = callback

		return subscribe(self, callback)
	end

	local facts: { Types.ActionRequestEvent } = {}
	local observation: Types.ActionObservationOwner = Observation.new(options(created, facts, {}))
	owner = observation
	assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))

	local original: RequestTypes.ActionRequestAdmission =
		assert(created.runtime:GetOriginalStart(1), "Expected original metadata")

	observation.Destroy()
	observation.Destroy()
	observation.SetInput(nil)
	assert(captured, "Expected captured source callback")(original)

	local disconnect = observation.Observe(function(): ()
		error("StaleObserver", 0)
	end)

	disconnect()
	expect(#facts).toBe(1)

	for _ = 1, 16 do
		created.runtime:ObserveAdmissions(function(): () end)
	end

	created.runtime:Destroy()
	local finalizers: number = 0

	created.runtime:AfterObservations(function(): ()
		finalizers += 1
	end)

	expect(finalizers).toBe(1)
end)
