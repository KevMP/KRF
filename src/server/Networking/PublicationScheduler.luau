--!strict
local PublicationTypes = require(script.Parent.PublicationTypes)

local PublicationScheduler = {}
PublicationScheduler.__index = PublicationScheduler

function PublicationScheduler.new(_options: PublicationTypes.SchedulerOptions): PublicationTypes.Scheduler
	return setmetatable({}, PublicationScheduler) :: any
end

function PublicationScheduler.Enqueue(
	_self: PublicationTypes.Scheduler,
	_stream: PublicationTypes.StreamKey,
	_commit: PublicationTypes.FilteredCommit
): (boolean, string?)
	error("N3NotImplemented", 2)
end

function PublicationScheduler.MarkBaselinePending(
	_self: PublicationTypes.Scheduler,
	_stream: PublicationTypes.StreamKey
): ()
	error("N3NotImplemented", 2)
end

function PublicationScheduler.ResetAfterBaseline(
	_self: PublicationTypes.Scheduler,
	_stream: PublicationTypes.StreamKey,
	_domains: { [string]: any }
): ()
	error("N3NotImplemented", 2)
end

function PublicationScheduler.RemoveStream(_self: PublicationTypes.Scheduler, _stream: PublicationTypes.StreamKey): ()
	error("N3NotImplemented", 2)
end

function PublicationScheduler.GetStreamStatus(
	_self: PublicationTypes.Scheduler,
	_stream: PublicationTypes.StreamKey
): PublicationTypes.StreamStatus
	error("N3NotImplemented", 2)
end

function PublicationScheduler.DrainBudgeted(
	_self: PublicationTypes.Scheduler,
	_maxBytes: number,
	_maxRecords: number
): PublicationTypes.DrainResult
	error("N3NotImplemented", 2)
end

function PublicationScheduler.Destroy(_self: PublicationTypes.Scheduler): ()
	-- Empty instance: no resources exist yet.
end

return PublicationScheduler
