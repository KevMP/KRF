--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local ServerNetworkingTypes = require(KRF.server.Networking.types)
local Scheduler: ServerNetworkingTypes.PublicationSchedulerModule =
	require(KRF.server.Networking.utils.PublicationScheduler)

local PublicationSchedulerTestUtils = {}

function PublicationSchedulerTestUtils.createScheduler(): ServerNetworkingTypes.PublicationScheduler
	return Scheduler.new({
		maxBarriers = 8,
		maxEvents = 16,
		maxQueuedBytes = 1024,
		-- Synthetic fixed-size encoder: every logical record costs exactly 16 bytes.
		-- These tests isolate scheduling; N2 codec sizing is tested separately.
		MeasureRecord = function(_commit: ServerNetworkingTypes.PublicationFilteredCommit): number
			return 16
		end,
	})
end

function PublicationSchedulerTestUtils.scalar(
	sequence: number,
	domainId: string,
	value: any,
	eventId: string?
): ServerNetworkingTypes.PublicationFilteredCommit
	local events: { ServerNetworkingTypes.PublicationEvent } = {}
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
	patch: ServerNetworkingTypes.PublicationPatch
): ServerNetworkingTypes.PublicationFilteredCommit
	return { sequence = sequence, patches = { { domainId = "Game.State", patch = patch } }, events = {} }
end

return PublicationSchedulerTestUtils
