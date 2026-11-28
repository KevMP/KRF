--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Presentation.types)
local AssetPreloader = require(KRF.client.Presentation.utils.AssetPreloader)
local AnimationTestUtils = require(script.Parent.AnimationTestUtils)

export type ScriptedStatus = {
	read contentId: unknown,
	read status: unknown,
}

export type PreloadCall = {
	targets: { Instance },
	record: (contentId: string, status: Enum.AssetFetchStatus) -> (),
	thread: thread?,
	returned: boolean,
}

export type Harness = {
	assets: Types.AssetsModule,
	calls: { PreloadCall },
	reports: { string },
	statuses: { ScriptedStatus },
	hold: boolean,
	failure: unknown,
}

local TestUtils = {}
local folders: { Instance } = {}

function TestUtils.Harness(): Harness
	local harness: Harness

	local port: Types.ContentPreloadPort = {
		PreloadAsync = function(
			targets: { Instance },
			record: (contentId: string, status: Enum.AssetFetchStatus) -> ()
		): ()
			local call: PreloadCall = {
				targets = table.clone(targets),
				record = record,
				thread = nil,
				returned = false,
			}

			table.insert(harness.calls, call)

			for _, scripted: ScriptedStatus in harness.statuses do
				(record :: any)(scripted.contentId, scripted.status)
			end

			if harness.hold then
				call.thread = coroutine.running()
				coroutine.yield()
			end

			local failure: unknown = harness.failure

			call.returned = true

			if failure ~= nil then
				error(failure, 0)
			end
		end,
		Report = function(reason: string): ()
			table.insert(harness.reports, reason)
		end,
	}

	harness = {
		assets = AssetPreloader.new(port),
		calls = {},
		reports = {},
		statuses = {},
		hold = false,
		failure = nil :: unknown,
	}

	return harness
end

function TestUtils.Release(call: PreloadCall): ()
	local thread: thread = assert(call.thread, "The preload call was not held")

	call.thread = nil
	task.spawn(thread)
end

function TestUtils.Settle(): ()
	task.wait()
end

function TestUtils.Folder(name: string): Folder
	local folder: Folder = Instance.new("Folder")
	folder.Name = name
	table.insert(folders, folder)

	return folder
end

function TestUtils.Child(className: string, parent: Instance): Instance
	local child: Instance = Instance.new(className :: any)
	child.Parent = parent

	return child
end

function TestUtils.IsDestroyed(instance: Instance): boolean
	return AnimationTestUtils.IsDestroyed(instance)
end

function TestUtils.Cleanup(): ()
	for _, folder: Instance in folders do
		folder:Destroy()
	end

	table.clear(folders)
end

return TestUtils
