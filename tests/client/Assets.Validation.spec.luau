--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local TestUtils = require(script.Parent.Utils.AssetTestUtils)

afterEach(function()
	TestUtils.Cleanup()
end)

it("refuses a value that is not a plain table of items", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local unsafe: any = harness.assets

	local cases: { any } = {
		nil,
		"rbxassetid://1",
		12,
		Instance.new("Sound"),
		setmetatable({ Instance.new("Sound") }, {}),
	}

	for index = 1, 5 do
		local accepted: boolean, reason: string? = unsafe.Preload(cases[index])

		expect(accepted).toBe(false)
		expect(reason).toBe("PreloadItemsInvalid")
	end

	TestUtils.Settle()

	expect(#harness.calls).toBe(0)
end)

it("refuses an empty list instead of scheduling a request with nothing to fetch", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	local accepted: boolean, reason: string? = harness.assets.Preload({})

	TestUtils.Settle()

	expect(accepted).toBe(false)
	expect(reason).toBe("PreloadItemsEmpty")
	expect(#harness.calls).toBe(0)
end)

it("refuses sparse and mapped lists with a stable reason", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local unsafe: any = harness.assets
	local sound: Sound = Instance.new("Sound")

	local labelled: { [any]: Sound } = { sound }

	labelled.extra = sound

	local cases: { any } = {
		{ [1] = sound, [3] = sound },
		{ [2] = sound },
		{ [0] = sound, [1] = sound },
		{ [1.5] = sound },
		{ [-1] = sound },
		{ [math.huge] = sound },
		{ sound = sound },
		labelled,
	}

	for _, items: any in cases do
		local accepted: boolean, reason: string? = unsafe.Preload(items)

		expect(accepted).toBe(false)
		expect(reason).toBe("PreloadItemsInvalid")
	end

	TestUtils.Settle()

	expect(#harness.calls).toBe(0)
end)

it("accepts 64 items and refuses a list with more entries than that", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local sound: Sound = Instance.new("Sound")
	local atLimit: { Sound } = table.create(64, sound)
	local overLimit: { Sound } = table.create(65, sound)
	local sparseOverLimit: { [number]: Instance } = {}

	for index = 1, 100 do
		sparseOverLimit[index * 2] = sound
	end

	local accepted: boolean = harness.assets.Preload(atLimit)
	local refused: boolean, reason: string? = harness.assets.Preload(overLimit)
	local sparse: boolean, sparseReason: string? = (harness.assets :: any).Preload(sparseOverLimit)

	expect(accepted).toBe(true)
	expect(refused).toBe(false)
	expect(reason).toBe("PreloadItemLimit")
	expect(sparse).toBe(false)
	expect(sparseReason).toBe("PreloadItemLimit")
end)

it("refuses a content ID string, a number or any value that is not an item", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local unsafe: any = harness.assets
	local sound: Sound = Instance.new("Sound")

	local cases: { any } = {
		"rbxassetid://123456",
		123456,
		true,
		function() end,
		Vector3.zero,
		setmetatable({ kind = "Sound", assetId = "rbxassetid://1" }, {}),
		{ kind = "Sound", assetId = "rbxassetid://1", volume = 1 },
		{ kind = "Sound", assetId = "rbxassetid://1", [1] = "extra" },
	}

	for _, item: any in cases do
		local accepted: boolean, reason: string? = unsafe.Preload({ sound, item })

		expect(accepted).toBe(false)
		expect(reason).toBe("PreloadItemInvalid")
	end

	TestUtils.Settle()

	expect(#harness.calls).toBe(0)
end)

it("refuses a descriptor whose kind is not Animation or Sound", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local unsafe: any = harness.assets

	local cases: { any } = {
		{ assetId = "rbxassetid://1" },
		{ kind = "Mesh", assetId = "rbxassetid://1" },
		{ kind = "animation", assetId = "rbxassetid://1" },
		{ kind = "ParticleEmitter", assetId = "rbxassetid://1" },
		{ kind = 1, assetId = "rbxassetid://1" },
	}

	for _, descriptor: any in cases do
		local accepted: boolean, reason: string? = unsafe.Preload({ descriptor })

		expect(accepted).toBe(false)
		expect(reason).toBe("PreloadKindInvalid")
	end
end)

it("refuses a descriptor whose asset ID is not a content ID", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local unsafe: any = harness.assets

	local cases: { any } = {
		nil,
		"",
		"123456",
		"rbxassetid://",
		"rbxassetid://abc",
		"rbxassetid://0",
		"rbxassetid://9223372036854775808",
		"rbxasset://sounds/electronicpingshort.wav",
		"https://example.com/asset/?id=12",
		123456,
	}

	for index = 1, 10 do
		local accepted: boolean, reason: string? = unsafe.Preload({ { kind = "Sound", assetId = cases[index] } })

		expect(accepted).toBe(false)
		expect(reason).toBe("PreloadAssetIdInvalid")
	end

	TestUtils.Settle()

	expect(#harness.calls).toBe(0)
end)

it("refuses an onComplete that is not a function", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local unsafe: any = harness.assets

	for _, onComplete: any in { "done", 1, true, {} } do
		local accepted: boolean, reason: string? = unsafe.Preload({ Instance.new("Sound") }, onComplete)

		expect(accepted).toBe(false)
		expect(reason).toBe("PreloadCallbackInvalid")
	end

	TestUtils.Settle()

	expect(#harness.calls).toBe(0)
end)

it("checks the item list before the callback and before capacity", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local unsafe: any = harness.assets

	harness.hold = true

	for _ = 1, 8 do
		harness.assets.Preload({ Instance.new("Sound") })
	end

	local invalid: boolean, invalidReason: string? = unsafe.Preload({}, "done")
	local busy: boolean, busyReason: string? = harness.assets.Preload({ Instance.new("Sound") })

	expect(invalid).toBe(false)
	expect(invalidReason).toBe("PreloadItemsEmpty")
	expect(busy).toBe(false)
	expect(busyReason).toBe("PreloadBusy")
end)

it("keeps refused requests from taking an in-flight slot", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local unsafe: any = harness.assets

	harness.hold = true

	for _ = 1, 20 do
		unsafe.Preload({ "rbxassetid://1" })
		unsafe.Preload({})
	end

	for _ = 1, 8 do
		local accepted: boolean = harness.assets.Preload({ Instance.new("Sound") })

		expect(accepted).toBe(true)
	end

	TestUtils.Settle()

	expect(#harness.calls).toBe(8)
end)
