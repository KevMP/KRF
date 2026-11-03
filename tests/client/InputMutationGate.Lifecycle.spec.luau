--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local MutationGate = require(ReplicatedStorage.Packages.KRF.client.Input.utils.InputMutationGate)

it("reports a failed queued mutation and still executes later mutations", function()
	local faults: { string } = {}

	local gate: MutationGate.Owner = MutationGate.new(function(): boolean
		return true
	end, function(reason: string): ()
		table.insert(faults, reason)
	end)

	local completed: boolean = false

	expect({ gate.Queue(function()
		error("QueuedMutationFailed", 0)
	end) }).toEqual({ true })

	expect({ gate.Queue(function()
		completed = true
	end) }).toEqual({ true })

	gate.Flush()
	expect(faults).toEqual({ "QueuedMutationFailed" })
	expect(completed).toBe(true)
end)

it("treats repeated terminal transitions as no-ops and never drains retired work", function()
	local faults: { string } = {}

	local gate: MutationGate.Owner = MutationGate.new(function(): boolean
		return true
	end, function(reason: string): ()
		table.insert(faults, reason)
	end)

	local calls: number = 0

	expect(gate.Queue(function()
		calls += 1
	end)).toBe(true)

	expect(gate.Fault()).toBe(true)
	expect(gate.Fault()).toBe(false)
	gate.Clear()
	gate.Flush()
	expect(gate.Destroy()).toBe(true)
	expect(gate.Destroy()).toBe(false)
	expect(gate.Fault()).toBe(false)
	expect(gate.Unavailable()).toBe("ClientNotReady")
	expect(calls).toBe(0)
	expect(faults).toEqual({})
end)
