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

local function preload(harness: TestUtils.Harness, items: { Types.PreloadItem }): { Types.PreloadReport }
	local reports: { Types.PreloadReport } = {}

	local accepted: boolean, reason: string? = harness.assets.Preload(items, function(report: Types.PreloadReport): ()
		table.insert(reports, report)
	end)

	assert(accepted, reason)

	TestUtils.Settle()
	TestUtils.Settle()

	return reports
end

it("reports every native status by content ID without merging them into one result", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.statuses = {
		{ contentId = "rbxassetid://1", status = Enum.AssetFetchStatus.Success },
		{ contentId = "rbxassetid://2", status = Enum.AssetFetchStatus.Failure },
		{ contentId = "rbxassetid://3", status = Enum.AssetFetchStatus.TimedOut },
		{ contentId = "rbxassetid://4", status = Enum.AssetFetchStatus.None },
		{ contentId = "rbxassetid://5", status = Enum.AssetFetchStatus.Loading },
	}

	local reports: { Types.PreloadReport } = preload(harness, { Instance.new("Sound") })

	expect(#reports).toBe(1)

	expect(reports[1].statuses).toEqual({
		["rbxassetid://1"] = Enum.AssetFetchStatus.Success,
		["rbxassetid://2"] = Enum.AssetFetchStatus.Failure,
		["rbxassetid://3"] = Enum.AssetFetchStatus.TimedOut,
		["rbxassetid://4"] = Enum.AssetFetchStatus.None,
		["rbxassetid://5"] = Enum.AssetFetchStatus.Loading,
	})

	expect(reports[1].error).toBeNil()
	expect(harness.reports).toEqual({})
end)

it("keeps the latest status when a content ID is reported more than once", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.statuses = {
		{ contentId = "rbxassetid://1", status = Enum.AssetFetchStatus.Loading },
		{ contentId = "rbxassetid://1", status = Enum.AssetFetchStatus.TimedOut },
		{ contentId = "rbxassetid://2", status = Enum.AssetFetchStatus.Success },
		{ contentId = "rbxassetid://2", status = Enum.AssetFetchStatus.Failure },
	}

	local reports: { Types.PreloadReport } = preload(harness, { Instance.new("Sound") })

	expect(reports[1].statuses).toEqual({
		["rbxassetid://1"] = Enum.AssetFetchStatus.TimedOut,
		["rbxassetid://2"] = Enum.AssetFetchStatus.Failure,
	})
end)

it("settles with an empty status map when the native call reports nothing", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	local reports: { Types.PreloadReport } = preload(harness, { Instance.new("Sound") })

	expect(#harness.calls).toBe(1)
	expect(reports[1].statuses).toEqual({})
	expect(reports[1].error).toBeNil()
end)

it("ignores native callback values that are not a content ID and an AssetFetchStatus", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.statuses = {
		{ contentId = 12, status = Enum.AssetFetchStatus.Success },
		{ contentId = "rbxassetid://1", status = "Success" },
		{ contentId = "rbxassetid://2", status = Enum.AnimationPriority.Action },
		{ contentId = "rbxassetid://3", status = Enum.AssetFetchStatus.Success },
	}

	local reports: { Types.PreloadReport } = preload(harness, { Instance.new("Sound") })

	expect(reports[1].statuses).toEqual({
		["rbxassetid://3"] = Enum.AssetFetchStatus.Success,
	})
end)

it("keeps statuses reported before the native call threw alongside the error", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.statuses = {
		{ contentId = "rbxassetid://1", status = Enum.AssetFetchStatus.Success },
	}

	harness.failure = "ContentProvider failed"

	local reports: { Types.PreloadReport } = preload(harness, { Instance.new("Sound") })

	expect(reports[1].statuses).toEqual({
		["rbxassetid://1"] = Enum.AssetFetchStatus.Success,
	})

	expect(reports[1].error).toBe("PreloadFailed:ContentProvider failed")
	expect(harness.reports).toEqual({ "PreloadFailed:ContentProvider failed" })
end)

it("names a non-string native error without exposing the value", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.failure = { code = 500 }

	local reports: { Types.PreloadReport } = preload(harness, { Instance.new("Sound") })

	expect(reports[1].error).toBe("PreloadFailed:NonStringError")
	expect(harness.reports).toEqual({ "PreloadFailed:NonStringError" })
end)

it("never retries a request whose content failed or whose native call threw", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.statuses = {
		{ contentId = "rbxassetid://1", status = Enum.AssetFetchStatus.Failure },
	}

	preload(harness, { Instance.new("Sound") })

	harness.failure = "ContentProvider failed"

	preload(harness, { Instance.new("Sound") })

	for _ = 1, 3 do
		TestUtils.Settle()
	end

	expect(#harness.calls).toBe(2)
end)

it("freezes the report and its status map", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.statuses = {
		{ contentId = "rbxassetid://1", status = Enum.AssetFetchStatus.Failure },
	}

	local report: Types.PreloadReport = preload(harness, { Instance.new("Sound") })[1]
	local unsafe: any = report

	expect(table.isfrozen(unsafe)).toBe(true)
	expect(table.isfrozen(unsafe.statuses)).toBe(true)

	local statusChanged: boolean = pcall(function(): ()
		unsafe.statuses["rbxassetid://1"] = Enum.AssetFetchStatus.Success
	end)

	local errorChanged: boolean = pcall(function(): ()
		unsafe.error = "changed"
	end)

	expect(statusChanged).toBe(false)
	expect(errorChanged).toBe(false)

	expect(report.statuses["rbxassetid://1"]).toBe(Enum.AssetFetchStatus.Failure)
end)

it("ignores native statuses that arrive after the request settled", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	local report: Types.PreloadReport = preload(harness, { Instance.new("Sound") })[1]

	harness.calls[1].record("rbxassetid://9", Enum.AssetFetchStatus.Success)

	expect(report.statuses).toEqual({})
end)

it("gives each request its own status map", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.statuses = {
		{ contentId = "rbxassetid://1", status = Enum.AssetFetchStatus.Success },
	}

	local first: Types.PreloadReport = preload(harness, { Instance.new("Sound") })[1]

	harness.statuses = {
		{ contentId = "rbxassetid://2", status = Enum.AssetFetchStatus.TimedOut },
	}

	local second: Types.PreloadReport = preload(harness, { Instance.new("Sound") })[1]

	expect(first.statuses).toEqual({ ["rbxassetid://1"] = Enum.AssetFetchStatus.Success })
	expect(second.statuses).toEqual({ ["rbxassetid://2"] = Enum.AssetFetchStatus.TimedOut })
end)

it("stays quiet about failed or timed-out content and leaves it to onComplete", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.statuses = {
		{ contentId = "rbxassetid://1", status = Enum.AssetFetchStatus.Failure },
		{ contentId = "rbxassetid://2", status = Enum.AssetFetchStatus.TimedOut },
	}

	harness.assets.Preload({ Instance.new("Sound") })

	TestUtils.Settle()
	TestUtils.Settle()

	expect(#harness.calls).toBe(1)
	expect(harness.reports).toEqual({})
end)
