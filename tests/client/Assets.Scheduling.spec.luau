--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Presentation.types)
local TestUtils = require(script.Parent.Utils.AssetTestUtils)

afterEach(function()
	TestUtils.Cleanup()
end)

it("returns before any native work and runs one native call on a deferred worker", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local sound: Sound = Instance.new("Sound")

	local accepted: boolean, reason: string? = harness.assets.Preload({ sound })

	expect(accepted).toBe(true)
	expect(reason).toBeNil()
	expect(#harness.calls).toBe(0)

	TestUtils.Settle()

	expect(#harness.calls).toBe(1)
	expect(harness.calls[1].targets).toEqual({ sound })
end)

it("never yields the caller, even when the native call yields", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local accepted: boolean? = nil

	harness.hold = true

	local caller: thread = coroutine.create(function(): ()
		accepted = harness.assets.Preload({ Instance.new("Sound") }, function(_report: Types.PreloadReport): () end)
	end)

	coroutine.resume(caller)

	expect(coroutine.status(caller)).toBe("dead")
	expect(accepted).toBe(true)

	TestUtils.Settle()

	expect(#harness.calls).toBe(1)
	expect(harness.calls[1].returned).toBe(false)
end)

it("refuses a ninth request while eight are still pending instead of queueing it", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.hold = true

	for _ = 1, 8 do
		local accepted: boolean = harness.assets.Preload({ Instance.new("Sound") })

		expect(accepted).toBe(true)
	end

	local refused: boolean, reason: string? = harness.assets.Preload({ Instance.new("Sound") })

	TestUtils.Settle()

	expect(refused).toBe(false)
	expect(reason).toBe("PreloadBusy")
	expect(#harness.calls).toBe(8)

	TestUtils.Release(harness.calls[1])
	TestUtils.Settle()

	expect(#harness.calls).toBe(8)
end)

it("counts requests that are scheduled but have not reached the native call", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	for _ = 1, 8 do
		harness.assets.Preload({ Instance.new("Sound") })
	end

	local refused: boolean, reason: string? = harness.assets.Preload({ Instance.new("Sound") })

	expect(refused).toBe(false)
	expect(reason).toBe("PreloadBusy")

	TestUtils.Settle()

	local accepted: boolean = harness.assets.Preload({ Instance.new("Sound") })

	expect(accepted).toBe(true)
end)

it("frees a slot as soon as its native call returns", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.hold = true

	for _ = 1, 8 do
		harness.assets.Preload({ Instance.new("Sound") })
	end

	TestUtils.Settle()
	TestUtils.Release(harness.calls[3])

	local accepted: boolean, reason: string? = harness.assets.Preload({ Instance.new("Sound") })

	expect(accepted).toBe(true)
	expect(reason).toBeNil()
end)

it("keeps a slot taken while its native call never returns", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.hold = true

	for _ = 1, 8 do
		harness.assets.Preload({ Instance.new("Sound") })
	end

	TestUtils.Settle()
	TestUtils.Release(harness.calls[1])
	harness.assets.Preload({ Instance.new("Sound") })
	TestUtils.Settle()

	local refused: boolean, reason: string? = harness.assets.Preload({ Instance.new("Sound") })

	expect(refused).toBe(false)
	expect(reason).toBe("PreloadBusy")
	expect(#harness.calls).toBe(9)
end)

it("reclaims the slot and temporary Instances of a worker whose thread was stopped", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local stoppedReports: { Types.PreloadReport } = {}

	harness.hold = true

	harness.assets.Preload({ { kind = "Sound", assetId = "rbxassetid://1" } }, function(report: Types.PreloadReport): ()
		table.insert(stoppedReports, report)
	end)

	for _ = 1, 7 do
		harness.assets.Preload({ Instance.new("Sound") })
	end

	TestUtils.Settle()

	local stopped: TestUtils.PreloadCall = harness.calls[1]
	local temporary: Instance = stopped.targets[1]

	coroutine.close(assert(stopped.thread, "The first worker was not held"))

	expect(TestUtils.IsDestroyed(temporary)).toBe(false)

	local accepted: boolean, reason: string? = harness.assets.Preload({ Instance.new("Sound") })
	local refused: boolean, refusedReason: string? = harness.assets.Preload({ Instance.new("Sound") })

	TestUtils.Settle()
	TestUtils.Settle()

	expect(accepted).toBe(true)
	expect(reason).toBeNil()
	expect(refused).toBe(false)
	expect(refusedReason).toBe("PreloadBusy")
	expect(TestUtils.IsDestroyed(temporary)).toBe(true)
	expect(#stoppedReports).toBe(0)
	expect(#harness.calls).toBe(9)
end)

it("frees the slot when the native call throws", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.failure = "ContentProvider failed"

	for _ = 1, 8 do
		harness.assets.Preload({ Instance.new("Sound") })
	end

	TestUtils.Settle()

	for _ = 1, 8 do
		local accepted: boolean = harness.assets.Preload({ Instance.new("Sound") })

		expect(accepted).toBe(true)
	end
end)

it("keeps a separate in-flight budget for each preloader", function()
	local first: TestUtils.Harness = TestUtils.Harness()
	local second: TestUtils.Harness = TestUtils.Harness()

	first.hold = true

	for _ = 1, 8 do
		first.assets.Preload({ Instance.new("Sound") })
	end

	local accepted: boolean = second.assets.Preload({ Instance.new("Sound") })

	expect(accepted).toBe(true)
end)

it("calls onComplete once, after the worker returns, on its own thread", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local reports: { Types.PreloadReport } = {}
	local workerThread: thread? = nil
	local callbackThread: thread? = nil

	harness.hold = true

	harness.assets.Preload({ Instance.new("Sound") }, function(report: Types.PreloadReport): ()
		callbackThread = coroutine.running()
		table.insert(reports, report)
	end)

	TestUtils.Settle()

	local call: TestUtils.PreloadCall = harness.calls[1]
	workerThread = call.thread

	TestUtils.Release(call)

	expect(#reports).toBe(0)

	TestUtils.Settle()
	TestUtils.Settle()

	expect(#reports).toBe(1)
	expect(callbackThread).never.toBe(workerThread)
end)

it("frees the slot before onComplete runs, so onComplete can start another preload", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local accepted: boolean? = nil
	local reason: string? = nil

	harness.hold = true

	harness.assets.Preload({ Instance.new("Sound") }, function(_report: Types.PreloadReport): ()
		accepted, reason = harness.assets.Preload({ Instance.new("Sound") })
	end)

	for _ = 1, 7 do
		harness.assets.Preload({ Instance.new("Sound") })
	end

	TestUtils.Settle()
	TestUtils.Release(harness.calls[1])
	TestUtils.Settle()

	expect(accepted).toBe(true)
	expect(reason).toBeNil()
end)

it("reports an onComplete error without affecting the slot or later requests", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local later: { Types.PreloadReport } = {}

	harness.assets.Preload({ Instance.new("Sound") }, function(_report: Types.PreloadReport): ()
		error("cosmetic fallback failed", 0)
	end)

	harness.assets.Preload({ Instance.new("Sound") }, function(_report: Types.PreloadReport): ()
		error({ code = 1 })
	end)

	TestUtils.Settle()
	TestUtils.Settle()

	harness.assets.Preload({ Instance.new("Sound") }, function(report: Types.PreloadReport): ()
		table.insert(later, report)
	end)

	TestUtils.Settle()
	TestUtils.Settle()

	expect(harness.reports).toEqual({
		"CompleteFailed:cosmetic fallback failed",
		"CompleteFailed:NonStringError",
	})

	expect(#later).toBe(1)
	expect(#harness.calls).toBe(3)
end)

it("lets onComplete yield without holding up other requests", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local resumed: boolean = false
	local blocked: thread? = nil
	local second: { Types.PreloadReport } = {}

	harness.assets.Preload({ Instance.new("Sound") }, function(_report: Types.PreloadReport): ()
		blocked = coroutine.running()
		coroutine.yield()
		resumed = true
	end)

	TestUtils.Settle()
	TestUtils.Settle()

	harness.assets.Preload({ Instance.new("Sound") }, function(report: Types.PreloadReport): ()
		table.insert(second, report)
	end)

	TestUtils.Settle()
	TestUtils.Settle()

	expect(#second).toBe(1)
	expect(resumed).toBe(false)

	task.spawn(assert(blocked, "onComplete never started"))

	expect(resumed).toBe(true)
	expect(#harness.reports).toBe(0)
end)

it("never calls onComplete while the native call is still pending", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local reports: { Types.PreloadReport } = {}

	harness.hold = true

	harness.assets.Preload({ Instance.new("Sound") }, function(report: Types.PreloadReport): ()
		table.insert(reports, report)
	end)

	for _ = 1, 5 do
		TestUtils.Settle()
	end

	expect(#reports).toBe(0)
	expect(#harness.reports).toBe(0)
end)
