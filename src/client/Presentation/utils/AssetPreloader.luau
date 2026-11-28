--!strict
local Types = require(script.Parent.Parent.types)
local Validator = require(script.Parent.Parent.AssetPreloadValidator)
local AssetPreloadTargets = require(script.Parent.AssetPreloadTargets)

local IN_FLIGHT_LIMIT: number = 8

type PreloadJob = {
	temporaries: { Instance },
	thread: thread?,
}

type PreloaderState = {
	port: Types.ContentPreloadPort,
	jobs: { [PreloadJob]: boolean },
	inFlight: number,
}

type OnComplete = (report: Types.PreloadReport) -> ()

local AssetPreloader = {}

local function describe(failure: unknown): string
	return if type(failure) == "string" then failure else "NonStringError"
end

local function deliver(port: Types.ContentPreloadPort, onComplete: OnComplete, report: Types.PreloadReport): ()
	local delivered: boolean, failure: unknown = pcall(onComplete, report)

	if not delivered then
		port.Report("CompleteFailed:" .. describe(failure))
	end
end

local function release(state: PreloaderState, job: PreloadJob): ()
	state.jobs[job] = nil
	state.inFlight -= 1
	AssetPreloadTargets.Release(job.temporaries)
end

local function reclaim(state: PreloaderState): ()
	for job: PreloadJob in state.jobs do
		local thread: thread? = job.thread

		if thread ~= nil and coroutine.status(thread) == "dead" then
			release(state, job)
		end
	end
end

local function work(
	state: PreloaderState,
	job: PreloadJob,
	request: Types.CompiledPreloadRequest,
	onComplete: OnComplete?
): ()
	local statuses: { [string]: Enum.AssetFetchStatus } = {}
	local settled: boolean = false

	local function record(contentId: unknown, status: unknown): ()
		if settled or type(contentId) ~= "string" or typeof(status) ~= "EnumItem" then
			return
		end

		local fetchStatus: EnumItem = status :: EnumItem

		if fetchStatus.EnumType == Enum.AssetFetchStatus then
			statuses[contentId] = fetchStatus :: Enum.AssetFetchStatus
		end
	end

	local ran: boolean, outcome: unknown = pcall(function(): string?
		local targets: { Instance }?, reason: string? = AssetPreloadTargets.Collect(request, job.temporaries)

		if targets == nil then
			return reason
		elseif #targets > 0 then
			state.port.PreloadAsync(targets, record)
		end

		return nil
	end)

	settled = true
	release(state, job)

	local reason: string? = nil

	if not ran then
		reason = "PreloadFailed:" .. describe(outcome)
	elseif type(outcome) == "string" then
		reason = outcome
	end

	local report: Types.PreloadReport = table.freeze({ statuses = table.freeze(statuses), error = reason })

	if reason ~= nil then
		state.port.Report(reason)
	end

	if onComplete ~= nil then
		task.defer(deliver, state.port, onComplete, report)
	end
end

function AssetPreloader.new(port: Types.ContentPreloadPort): Types.AssetsModule
	local state: PreloaderState = { port = port, jobs = {}, inFlight = 0 }

	local function preload(items: { read [number]: Types.PreloadItem }, onComplete: OnComplete?): (boolean, string?)
		local request: Types.CompiledPreloadRequest?, reason: string? = Validator.Request(items, onComplete)

		if request == nil then
			return false, reason
		elseif state.inFlight >= IN_FLIGHT_LIMIT then
			reclaim(state)
		end

		if state.inFlight >= IN_FLIGHT_LIMIT then
			return false, "PreloadBusy"
		end

		local job: PreloadJob = { temporaries = {}, thread = nil }

		state.jobs[job] = true
		state.inFlight += 1
		job.thread = task.defer(work, state, job, request, onComplete)

		return true, nil
	end

	return table.freeze({ Preload = preload })
end

return table.freeze(AssetPreloader)
