--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local PublicationTypes = require(KRF.server.Networking.PublicationTypes)
local Scheduler: PublicationTypes.SchedulerModule = require(KRF.server.Networking.PublicationScheduler)

local PublicationSchedulerTestUtils = {}

function PublicationSchedulerTestUtils.createScheduler(): PublicationTypes.Scheduler
	return Scheduler.new({
		maxBarriers = 8,
		maxEvents = 16,
		maxQueuedBytes = 1024,
		-- Synthetic fixed-size encoder: every logical record costs exactly 16 bytes.
		-- These tests isolate scheduling; N2 codec sizing is tested separately.
		MeasureRecord = function(_commit: PublicationTypes.FilteredCommit): number
			return 16
		end,
	})
end

function PublicationSchedulerTestUtils.scalar(
	sequence: number,
	domainId: string,
	value: any,
	eventId: string?
): PublicationTypes.FilteredCommit
	local events: { PublicationTypes.Event } = {}
	if eventId ~= nil then
		table.insert(events, { domainId = domainId, eventId = eventId, payload = {} })
	end
	return {
		sequence = sequence,
		patches = { { domainId = domainId, patch = { kind = "Replace", value = value } } },
		events = events,
	}
end

function PublicationSchedulerTestUtils.patch(
	sequence: number,
	patch: PublicationTypes.Patch
): PublicationTypes.FilteredCommit
	return { sequence = sequence, patches = { { domainId = "Game.State", patch = patch } }, events = {} }
end

return PublicationSchedulerTestUtils
