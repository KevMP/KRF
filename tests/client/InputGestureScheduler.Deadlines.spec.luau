--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local Types = require(KRF.client.Input.types)
local Scheduler = require(KRF.client.Input.utils.InputGestureScheduler)
local Constants = require(KRF.client.Input.utils.InputConstants)

type Alarm = { deadline: number, callback: () -> (), cancelled: boolean, fired: boolean }
local now: number = 0
local alarms: { Alarm } = {}
local faults: { string } = {}
local scheduler: Types.GestureScheduler

beforeEach(function()
	now = 0
	alarms = {}
	faults = {}

	scheduler = Scheduler.new(function(): number
		return now
	end, function(reason: string): ()
		table.insert(faults, reason)
	end, function(seconds: number, callback: () -> ()): () -> ()
		local entry: Alarm = { deadline = now + seconds, callback = callback, cancelled = false, fired = false }
		table.insert(alarms, entry)

		return function(): ()
			entry.cancelled = true
		end
	end)
end)

local function wake(at: number): ()
	now = at
	local snapshot: { Alarm } = table.clone(alarms)

	for _, entry: Alarm in snapshot do
		if not entry.cancelled and not entry.fired and entry.deadline <= now then
			entry.fired = true
			entry.callback()
		end
	end
end

it("orders a late wake by deadline then insertion order with only one live engine alarm", function()
	local calls: { number } = {}

	for _, deadline: number in { 8, 3, 7, 1, 5, 3, 6, 2, 4 } do
		scheduler.Schedule(deadline, function()
			table.insert(calls, deadline)
		end)
	end

	local live: number = 0

	for _, entry: Alarm in alarms do
		if not entry.cancelled then
			live += 1
		end
	end

	expect(live).toBe(1)
	wake(10)
	expect(calls).toEqual({ 1, 2, 3, 3, 4, 5, 6, 7, 8 })
	expect(faults).toEqual({})
end)

it("removes arbitrary deadlines and ignores stale callbacks after alarm replacement", function()
	local calls: { number } = {}
	local stops: { () -> () } = {}

	for index: number, deadline: number in { 1, 9, 3, 8, 2, 7, 4, 6, 5 } do
		stops[index] = scheduler.Schedule(deadline, function()
			table.insert(calls, deadline)
		end)
	end

	stops[1]()
	stops[4]()
	stops[2]()
	stops[9]()
	stops[1]()
	alarms[1].callback()
	expect(calls).toEqual({})
	wake(20)
	expect(calls).toEqual({ 2, 3, 4, 6, 7 })

	for _, stop in stops do
		stop()
	end
end)

it("rearams an early wake and gives newly scheduled due work another scheduler turn", function()
	local calls: { string } = {}

	scheduler.Schedule(1, function()
		table.insert(calls, "First")

		scheduler.Schedule(now, function()
			table.insert(calls, "Nested")
		end)
	end)

	alarms[1].fired = true
	alarms[1].callback()
	expect(calls).toEqual({})
	wake(1)
	expect(calls).toEqual({ "First" })
	wake(1)
	expect(calls).toEqual({ "First", "Nested" })
end)

it("contains a callback error while delivering another deadline and permits cancellation during delivery", function()
	local calls: number = 0
	local stop: () -> () = function() end

	scheduler.Schedule(1, function()
		stop()
		error("DeadlineConsumerFailed", 0)
	end)

	stop = scheduler.Schedule(1, function()
		calls += 100
	end)

	scheduler.Schedule(1, function()
		calls += 1
	end)

	wake(1)
	expect(calls).toBe(1)
	expect(faults).toEqual({ "DeadlineConsumerFailed" })
end)

it("rejects invalid and excess deadlines and recovers capacity when a pending deadline is cancelled", function()
	local invalid: boolean, invalidReason: any = pcall(scheduler.Schedule, math.huge, function() end)
	expect(invalid).toBe(false)
	expect(tostring(invalidReason)).toContain("InvalidGestureDeadline")
	local stops: { () -> () } = {}

	for _ = 1, Constants.MAX_GESTURE_DEADLINES do
		table.insert(stops, scheduler.Schedule(5, function() end))
	end

	local overflow: boolean, reason: any = pcall(scheduler.Schedule, 5, function() end)
	expect(overflow).toBe(false)
	expect(tostring(reason)).toContain("InputGestureDeadlineLimitExceeded")
	stops[1]()
	local replacement: () -> () = scheduler.Schedule(1, function() end)
	replacement()

	for _, stop in stops do
		stop()
	end

	expect(alarms[#alarms].cancelled).toBe(true)
end)

it("uses cancellable task deadlines with the production clock without polling frames", function()
	local calls: number = 0

	local native: Types.GestureScheduler = Scheduler.new(os.clock, function(reason: string)
		error(reason, 0)
	end)

	local stop: () -> () = native.Schedule(os.clock() + 10, function()
		calls += 100
	end)

	native.Schedule(os.clock(), function()
		calls += 1
	end)

	stop()
	task.wait(0.05)
	expect(calls).toBe(1)
end)
