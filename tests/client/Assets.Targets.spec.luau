--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
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

it("builds an unparented Animation or Sound for each descriptor", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.hold = true

	harness.assets.Preload({
		{ kind = "Animation", assetId = "rbxassetid://507766388" },
		{ kind = "Sound", assetId = " https://www.roblox.com/asset/?id=0654321 " },
	})

	TestUtils.Settle()

	local targets: { Instance } = harness.calls[1].targets
	local animation: Animation = targets[1] :: Animation
	local sound: Sound = targets[2] :: Sound

	expect(#targets).toBe(2)
	expect(animation.ClassName).toBe("Animation")
	expect(animation.AnimationId).toBe("rbxassetid://507766388")
	expect(animation.Parent).toBeNil()
	expect(sound.ClassName).toBe("Sound")
	expect(sound.SoundId).toBe("rbxassetid://654321")
	expect(sound.Parent).toBeNil()
	expect(sound.IsPlaying).toBe(false)
end)

it("keeps temporary Instances alive across the native yield and destroys them after it returns", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.hold = true

	harness.assets.Preload({ { kind = "Animation", assetId = "rbxassetid://1" } })

	TestUtils.Settle()
	TestUtils.Settle()

	local call: TestUtils.PreloadCall = harness.calls[1]
	local animation: Instance = call.targets[1]

	expect(TestUtils.IsDestroyed(animation)).toBe(false)

	TestUtils.Release(call)

	expect(TestUtils.IsDestroyed(animation)).toBe(true)
end)

it("destroys temporary Instances before onComplete runs", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local destroyedInCallback: boolean? = nil

	harness.assets.Preload(
		{ { kind = "Sound", assetId = "rbxassetid://1" } },
		function(_report: Types.PreloadReport): ()
			destroyedInCallback = TestUtils.IsDestroyed(harness.calls[1].targets[1])
		end
	)

	TestUtils.Settle()
	TestUtils.Settle()

	expect(destroyedInCallback).toBe(true)
end)

it("destroys temporary Instances when the native call throws", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.failure = "ContentProvider failed"

	harness.assets.Preload({
		{ kind = "Animation", assetId = "rbxassetid://1" },
		{ kind = "Sound", assetId = "rbxassetid://2" },
	})

	TestUtils.Settle()

	for _, target: Instance in harness.calls[1].targets do
		expect(TestUtils.IsDestroyed(target)).toBe(true)
	end
end)

it("passes a game-owned Instance as itself and never moves, changes or destroys it", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local folder: Folder = TestUtils.Folder("Owned")

	local emitter: ParticleEmitter = TestUtils.Child("ParticleEmitter", folder) :: ParticleEmitter

	emitter.Texture = "rbxassetid://777"
	emitter.Enabled = false

	harness.assets.Preload({ emitter })

	TestUtils.Settle()

	expect(harness.calls[1].targets[1]).toBe(emitter)
	expect(emitter.Parent).toBe(folder)
	expect(emitter.Texture).toBe("rbxassetid://777")
	expect(emitter.Enabled).toBe(false)
	expect(TestUtils.IsDestroyed(emitter)).toBe(false)
	expect(#folder:GetChildren()).toBe(1)
end)

it("collects only content-bearing descendants of a selected Folder or Model", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local folder: Folder = TestUtils.Folder("Fireball")
	local sound: Instance = TestUtils.Child("Sound", folder)
	local model: Instance = TestUtils.Child("Model", folder)
	local part: Instance = TestUtils.Child("Part", model)
	local emitter: Instance = TestUtils.Child("ParticleEmitter", part)
	local decal: Instance = TestUtils.Child("Decal", part)
	local texture: Instance = TestUtils.Child("Texture", part)
	local animation: Instance = TestUtils.Child("Animation", model)

	TestUtils.Child("Script", folder)
	TestUtils.Child("LocalScript", model)
	TestUtils.Child("ModuleScript", part)
	TestUtils.Child("StringValue", folder)
	TestUtils.Child("Attachment", part)
	TestUtils.Child("Folder", model)

	harness.assets.Preload({ folder })

	TestUtils.Settle()

	local targets: { Instance } = harness.calls[1].targets
	local collected: { [Instance]: boolean } = {}

	for _, target: Instance in targets do
		collected[target] = true
	end

	expect(#targets).toBe(5)

	expect(collected).toEqual({
		[sound] = true,
		[emitter] = true,
		[decal] = true,
		[texture] = true,
		[animation] = true,
	})
end)

it("collects every content-bearing class KRF recognizes", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local folder: Folder = TestUtils.Folder("Classes")
	local part: Instance = TestUtils.Child("Part", folder)

	local classes: { string } = {
		"Animation",
		"Sound",
		"ParticleEmitter",
		"Beam",
		"Trail",
		"Decal",
		"Texture",
		"MeshPart",
		"SpecialMesh",
		"ImageLabel",
		"ImageButton",
		"Sky",
	}

	for _, className: string in classes do
		TestUtils.Child(className, part)
	end

	harness.assets.Preload({ folder })

	TestUtils.Settle()

	local collected: { string } = {}

	for _, target: Instance in harness.calls[1].targets do
		table.insert(collected, target.ClassName)
	end

	table.sort(collected)
	table.sort(classes)

	expect(collected).toEqual(classes)
end)

it("skips SurfaceAppearance and MaterialVariant, which PreloadAsync does not fetch", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local reports: { Types.PreloadReport } = {}
	local folder: Folder = TestUtils.Folder("Unsupported")
	local surface: Instance = TestUtils.Child("SurfaceAppearance", TestUtils.Child("MeshPart", folder))
	local variant: Instance = TestUtils.Child("MaterialVariant", folder)

	harness.assets.Preload({ surface, variant }, function(report: Types.PreloadReport): ()
		table.insert(reports, report)
	end)

	TestUtils.Settle()
	TestUtils.Settle()

	expect(#harness.calls).toBe(0)
	expect(#reports).toBe(1)
	expect(reports[1].statuses).toEqual({})
	expect(reports[1].error).toBeNil()
end)

it("settles with an empty report and no native call when nothing selected carries content", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local reports: { Types.PreloadReport } = {}
	local folder: Folder = TestUtils.Folder("Empty")

	TestUtils.Child("Script", folder)
	TestUtils.Child("NumberValue", folder)

	harness.assets.Preload({ folder, TestUtils.Child("Part", folder) }, function(report: Types.PreloadReport): ()
		table.insert(reports, report)
	end)

	TestUtils.Settle()
	TestUtils.Settle()

	expect(#harness.calls).toBe(0)
	expect(reports[1].statuses).toEqual({})
	expect(reports[1].error).toBeNil()
end)

it("loads a selected Folder in Workspace without its siblings or ancestors", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local area: Folder = TestUtils.Folder("Area")
	local selected: Instance = TestUtils.Child("Folder", area)
	local sibling: Instance = TestUtils.Child("Folder", area)
	local wanted: Instance = TestUtils.Child("Sound", selected)

	TestUtils.Child("Sound", sibling)
	TestUtils.Child("Sound", area)
	area.Parent = Workspace

	harness.assets.Preload({ selected })

	TestUtils.Settle()

	expect(harness.calls[1].targets).toEqual({ wanted })
end)

it("passes each Instance once when it is listed twice or also inside a listed Folder", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local folder: Folder = TestUtils.Folder("Overlap")
	local sound: Instance = TestUtils.Child("Sound", folder)

	local twin: Sound = TestUtils.Child("Sound", folder) :: Sound

	twin.SoundId = (sound :: Sound).SoundId

	harness.assets.Preload({ sound, folder, sound, folder })

	TestUtils.Settle()

	expect(harness.calls[1].targets).toEqual({ sound, twin })
end)

it("builds one temporary Instance for descriptors that name the same asset", function()
	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.assets.Preload({
		{ kind = "Sound", assetId = "rbxassetid://42" },
		{ kind = "Sound", assetId = "RBXASSETID://0042" },
		{ kind = "Animation", assetId = "rbxassetid://42" },
		{ kind = "Sound", assetId = "rbxassetid://43" },
	})

	TestUtils.Settle()

	local described: { string } = {}

	for _, target: Instance in harness.calls[1].targets do
		local id: string = if target:IsA("Sound") then target.SoundId else (target :: Animation).AnimationId

		table.insert(described, target.ClassName .. " " .. id)
	end

	table.sort(described)

	expect(described).toEqual({
		"Animation rbxassetid://42",
		"Sound rbxassetid://42",
		"Sound rbxassetid://43",
	})
end)

it("reports a descendant limit without a native call when a selection is too large", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local reports: { Types.PreloadReport } = {}
	local folder: Folder = TestUtils.Folder("Huge")

	for _ = 1, 2048 do
		Instance.new("Folder").Parent = folder
	end

	harness.assets.Preload(
		{ folder, { kind = "Sound", assetId = "rbxassetid://1" } },
		function(report: Types.PreloadReport): ()
			table.insert(reports, report)
		end
	)

	TestUtils.Settle()
	TestUtils.Settle()

	expect(#harness.calls).toBe(0)
	expect(reports[1].error).toBe("PreloadDescendantLimit")
	expect(reports[1].statuses).toEqual({})
	expect(harness.reports).toEqual({ "PreloadDescendantLimit" })
end)

it("visits up to 2048 Instances across a request", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local first: Folder = TestUtils.Folder("First")
	local second: Folder = TestUtils.Folder("Second")

	for _ = 1, 1023 do
		Instance.new("Folder").Parent = first
		Instance.new("Folder").Parent = second
	end

	local sound: Instance = TestUtils.Child("Sound", second)
	local reports: { Types.PreloadReport } = {}

	harness.assets.Preload({ first, second }, function(report: Types.PreloadReport): ()
		table.insert(reports, report)
	end)

	TestUtils.Settle()
	TestUtils.Settle()

	expect(#harness.calls).toBe(0)
	expect(reports[1].error).toBe("PreloadDescendantLimit")

	first:GetChildren()[1]:Destroy()

	harness.assets.Preload({ first, second })

	TestUtils.Settle()

	expect(#harness.calls).toBe(1)
	expect(harness.calls[1].targets).toEqual({ sound })
end)

it("reports a target limit when a selection holds more than 256 content Instances", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local reports: { Types.PreloadReport } = {}
	local folder: Folder = TestUtils.Folder("Sounds")

	for _ = 1, 255 do
		Instance.new("Sound").Parent = folder
	end

	harness.assets.Preload({ folder, { kind = "Animation", assetId = "rbxassetid://1" } })

	TestUtils.Settle()

	expect(#harness.calls[1].targets).toBe(256)

	Instance.new("Sound").Parent = folder

	harness.assets.Preload(
		{ folder, { kind = "Animation", assetId = "rbxassetid://1" } },
		function(report: Types.PreloadReport): ()
			table.insert(reports, report)
		end
	)

	TestUtils.Settle()
	TestUtils.Settle()

	expect(#harness.calls).toBe(1)
	expect(reports[1].error).toBe("PreloadTargetLimit")
	expect(harness.reports).toEqual({ "PreloadTargetLimit" })
end)

it("reads a selected Folder when its worker runs, not when Preload is called", function()
	local harness: TestUtils.Harness = TestUtils.Harness()
	local folder: Folder = TestUtils.Folder("Late")

	harness.assets.Preload({ folder })

	local added: Instance = TestUtils.Child("Sound", folder)

	TestUtils.Settle()

	expect(harness.calls[1].targets).toEqual({ added })
end)
