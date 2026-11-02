--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local InputTestUtils = require(script.Parent.InputTestUtils)

export type Job = { deadline: number, callback: () -> (), cancelled: boolean, fired: boolean }

export type Fixture = {
	input: InputTestUtils.Fixture,
	events: { Types.GestureEvent },
	groups: { Types.GestureDispatchGroup },
	jobs: { Job },
	onGesture: ((Types.GestureEvent) -> ())?,
}

local Utils = {}

function Utils.new(): Fixture
	local fixture: Fixture
	local events: { Types.GestureEvent } = {}
	local jobs: { Job } = {}

	local input: InputTestUtils.Fixture = InputTestUtils.new({
		Scheduler = {
			Schedule = function(deadline: number, callback: () -> ()): () -> ()
				local job: Job = { deadline = deadline, callback = callback, cancelled = false, fired = false }
				table.insert(jobs, job)

				return function(): ()
					job.cancelled = true
				end
			end,
		},
		PublishGesture = function(event: Types.GestureEvent): ()
			table.insert(events, event)
			local notify: ((Types.GestureEvent) -> ())? = fixture.onGesture

			if notify ~= nil then
				notify(event)
			end
		end,
	})

	fixture =
		{ input = input, events = events, groups = {}, jobs = jobs, onGesture = nil :: ((Types.GestureEvent) -> ())? }

	input.now = 0

	input.owner.ObserveDispatchGroup(function(group: Types.GestureDispatchGroup)
		table.insert(fixture.groups, group)
	end)

	InputTestUtils.install(input)
	InputTestUtils.enable(input)

	return fixture
end

function Utils.install(fixture: Fixture, definitions: Types.GestureDefinitions, sourceId: string?): (boolean, string?)
	return fixture.input.owner.SetSource(sourceId or "Gestures", { gestures = { Primary = definitions } })
end

function Utils.emit(fixture: Fixture, time: number, kind: Types.NativeTransition, inputId: string?): ()
	fixture.input.now = time
	InputTestUtils.emit(fixture.input, kind, kind == "Pressed", inputId)
end

function Utils.tap(fixture: Fixture, pressed: number, released: number, inputId: string?): ()
	Utils.emit(fixture, pressed, "Pressed", inputId)
	Utils.emit(fixture, released, "Released", inputId)
end

-- One scheduler turn: snapshot first so equality-time rescheduling cannot spin here.
function Utils.wake(fixture: Fixture, time: number): ()
	fixture.input.now = time

	local due: { Job } = {}

	for _, job: Job in fixture.jobs do
		if not job.cancelled and not job.fired and job.deadline <= time then
			table.insert(due, job)
		end
	end

	table.sort(due, function(left: Job, right: Job): boolean
		return left.deadline < right.deadline
	end)

	for _, job: Job in due do
		if not job.cancelled then
			job.fired = true
			job.callback()
		end
	end
end

function Utils.pending(fixture: Fixture): number
	local count: number = 0

	for _, job: Job in fixture.jobs do
		if not job.cancelled and not job.fired then
			count += 1
		end
	end

	return count
end

function Utils.kinds(fixture: Fixture): { string }
	local result: { string } = {}

	for _, event: Types.GestureEvent in fixture.events do
		table.insert(result, event.gesture)
	end

	return result
end

function Utils.candidates(group: Types.GestureDispatchGroup): { string }
	local result: { string } = {}

	for _, candidate: Types.GestureCandidate in group.candidates do
		if candidate.routeEligible then
			table.insert(result, candidate.key)
		end
	end

	return result
end

function Utils.pair(policy: Types.DoubleTapArbitration?): Types.GestureDefinitions
	return {
		Tap = { maxDurationSeconds = 0.25 },
		DoubleTapped = { maxTapDurationSeconds = 0.25, maxGapSeconds = 0.5, arbitration = policy },
	}
end

function Utils.destroy(fixture: Fixture): ()
	InputTestUtils.destroy(fixture.input)
end

return Utils
