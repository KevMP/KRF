--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local MutationGate = require(KRF.client.Input.utils.InputMutationGate)

it("rejects unavailable or nested control barriers without disturbing the outer owner", function()
	local ready: boolean = false

	local gate: MutationGate.Owner = MutationGate.new(function(): boolean
		return ready
	end, function() end)

	expect({ gate.BeginCoordination() }).toEqual({ false, "ClientNotReady" })
	ready = true
	expect({ gate.BeginCoordination() }).toEqual({ true })
	expect({ gate.BeginCoordination() }).toEqual({ false, "DispatchInProgress" })
	gate.EndCoordination()
	gate.EnterDispatch()
	expect({ gate.BeginCoordination() }).toEqual({ false, "DispatchInProgress" })
	gate.LeaveDispatch()
	expect({ gate.BeginCoordination() }).toEqual({ true })
	gate.EndCoordination()
end)

it("bounds self-replenishing original follow-up work and refuses callbacks after terminal fault", function()
	local faults: { string } = {}

	local gate: MutationGate.Owner = MutationGate.new(function(): boolean
		return true
	end, function(reason): ()
		table.insert(faults, reason)
	end)

	local calls: number = 0
	local repeatWork: () -> ()

	repeatWork = function(): ()
		calls += 1
		gate.AfterCommit(repeatWork)
	end

	expect({ gate.BeginCoordination() }).toEqual({ true })
	gate.AfterCommit(repeatWork)
	gate.DrainAfterCommit()
	expect(calls).toBe(64)
	expect(faults).toEqual({ "InputMutationQueueLimitExceeded" })
	gate.EndCoordination()
	gate.Fault()

	expect({ gate.AfterCommit(function(): ()
		error("RetiredFollowUpRan", 0)
	end) }).toEqual({ false, "ClientNotReady" })

	gate.DrainAfterCommit()
end)
