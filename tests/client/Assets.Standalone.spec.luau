--!strict
local LogService = game:GetService("LogService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local KRF = require(ReplicatedStorage.Packages.KRF)
local Client = require(ReplicatedStorage.Packages.KRF.client)
local Assets = require(ReplicatedStorage.Packages.KRF.client.Presentation.Assets)
local NativeContentPort = require(ReplicatedStorage.Packages.KRF.client.Presentation.utils.NativeContentPort)
local TestUtils = require(script.Parent.Utils.AssetTestUtils)

afterEach(function()
	TestUtils.Cleanup()
end)

it("is the same frozen module through the KRF facade and its require path", function()
	local unsafe: any = KRF.Assets

	expect(KRF.Assets).toBe(Assets)
	expect(table.isfrozen(unsafe)).toBe(true)

	local replaced: boolean = pcall(function(): ()
		unsafe.Preload = function() end
	end)

	expect(replaced).toBe(false)
end)

it("settles a request through KRF.Assets without Client.Init", function()
	local folder: Folder = TestUtils.Folder("NoContent")
	local reports: { KRF.PreloadReport } = {}

	TestUtils.Child("Folder", folder)

	local accepted: boolean, reason: string? = KRF.Assets.Preload({ folder }, function(report: KRF.PreloadReport): ()
		table.insert(reports, report)
	end)

	expect(accepted).toBe(true)
	expect(reason).toBeNil()

	local deadline: number = os.clock() + 5

	while #reports == 0 and os.clock() < deadline do
		task.wait()
	end

	expect(Client._IsInitialized()).toBe(false)
	expect(#reports).toBe(1)
	expect(reports[1].statuses).toEqual({})
	expect(reports[1].error).toBeNil()
end)

it("returns from a native call whose targets carry no content", function()
	local folder: Folder = TestUtils.Folder("Native")
	local reported: { string } = {}

	NativeContentPort.PreloadAsync({ folder }, function(contentId: string, _status: Enum.AssetFetchStatus): ()
		table.insert(reported, contentId)
	end)

	expect(reported).toEqual({})
end)

it("warns native diagnostics with the Assets prefix", function()
	local warnings: { string } = {}

	local connection: RBXScriptConnection = LogService.MessageOut:Connect(
		function(message: string, messageType: Enum.MessageType): ()
			if messageType == Enum.MessageType.MessageWarning then
				table.insert(warnings, message)
			end
		end
	)

	NativeContentPort.Report("PreloadDescendantLimit")
	task.wait()
	connection:Disconnect()

	expect(table.find(warnings, "[Assets] reason=PreloadDescendantLimit")).never.toBeNil()
end)

it("preloads a rig's Animation without creating an Animator or loading a track", function()
	local folder: Folder = TestUtils.Folder("Rig")
	local model: Instance = TestUtils.Child("Model", folder)
	local humanoid: Instance = TestUtils.Child("Humanoid", model)

	local animation: Animation = TestUtils.Child("Animation", model) :: Animation

	animation.AnimationId = "rbxassetid://507766388"

	local harness: TestUtils.Harness = TestUtils.Harness()

	harness.assets.Preload({ model, { kind = "Animation", assetId = "rbxassetid://507766388" } })

	TestUtils.Settle()

	expect(#harness.calls[1].targets).toBe(2)
	expect(humanoid:FindFirstChildOfClass("Animator")).toBeNil()
	expect(#model:GetChildren()).toBe(2)
end)
