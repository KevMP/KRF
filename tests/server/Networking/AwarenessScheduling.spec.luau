--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ServerNetworkingTypes = require(KRF.server.Networking.types)

local Scheduling: ServerNetworkingTypes.AwarenessSchedulingModule =
	require(KRF.server.Networking.utils.AwarenessScheduling)

local disconnect: (() -> ())? = nil

afterEach(function()
	if disconnect ~= nil then
		disconnect()
		disconnect = nil
	end
end)

it("emits scheduling events from native frames and stops them when disconnected", function()
	local calls: number = 0

	disconnect = Scheduling.ObserveStep(function(): ()
		calls += 1
	end)

	-- Bounded native-frame waits; no wait depends on the missing N4 callback.
	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
	task.wait()
	expect(calls > 0).toBe(true)
	assert(disconnect ~= nil, "Expected owned native subscription")
	disconnect()
	disconnect()
	local before: number = calls
	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
	task.wait()
	expect(calls).toBe(before)
end)

it("provides finite positive byte and record budgets for the production driver", function()
	local budget: ServerNetworkingTypes.AwarenessStepBudget = Scheduling.GetBudget()
	expect(budget.maxBytes > 0 and budget.maxBytes < math.huge and budget.maxBytes % 1 == 0).toBe(true)
	expect(budget.maxRecords > 0 and budget.maxRecords < math.huge and budget.maxRecords % 1 == 0).toBe(true)
end)
