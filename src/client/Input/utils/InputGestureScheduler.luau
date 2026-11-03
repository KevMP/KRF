--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.InputConstants)
local Value = require(script.Parent.InputValue)

type Entry = { deadline: number, ordinal: number, callback: () -> (), index: number }

export type Alarm = (seconds: number, callback: () -> ()) -> () -> ()

local Scheduler = {}

local function alarm(seconds: number, callback: () -> ()): () -> ()
	local worker: thread = task.delay(seconds, callback)

	return function(): ()
		pcall(task.cancel, worker)
	end
end

-- One engine wakeup for the earliest live deadline; cancellation removes heap
-- entries immediately, including callbacks that capture retired input owners.
function Scheduler.new(now: () -> number, report: (string) -> (), makeAlarm: Alarm?): Types.GestureScheduler
	local heap: { Entry } = {}
	local nextOrdinal: number = 0
	local cancelAlarm: (() -> ())? = nil
	local armedDeadline: number? = nil
	local alarmGeneration: number = 0
	local waking: boolean = false
	local createAlarm: Alarm = makeAlarm or alarm
	local arm: () -> ()

	local function before(left: Entry, right: Entry): boolean
		return left.deadline < right.deadline or (left.deadline == right.deadline and left.ordinal < right.ordinal)
	end

	local function swap(left: number, right: number): ()
		heap[left], heap[right] = heap[right], heap[left]
		heap[left].index = left
		heap[right].index = right
	end

	local function up(index: number): number
		while index > 1 do
			local parent: number = math.floor(index / 2)

			if not before(heap[index], heap[parent]) then
				break
			end

			swap(index, parent)
			index = parent
		end

		return index
	end

	local function remove(entry: Entry): ()
		local index: number = entry.index
		local last: Entry = assert(table.remove(heap), "Expected scheduled deadline")

		entry.index = 0

		if last == entry then
			return
		end

		heap[index] = last
		last.index = index
		index = up(index)

		while index * 2 <= #heap do
			local child: number = index * 2

			if child < #heap and before(heap[child + 1], heap[child]) then
				child += 1
			end

			if not before(heap[child], heap[index]) then
				break
			end

			swap(index, child)
			index = child
		end
	end

	arm = function(): ()
		if waking then
			return
		end

		local earliest: Entry? = heap[1]
		local deadline: number? = if earliest ~= nil then earliest.deadline else nil

		if deadline == armedDeadline then
			return
		end

		alarmGeneration += 1

		if cancelAlarm ~= nil then
			cancelAlarm()
			cancelAlarm = nil
		end

		armedDeadline = deadline

		if deadline == nil then
			return
		end

		local generation: number = alarmGeneration

		cancelAlarm = createAlarm(math.max(0, deadline - now()), function(): ()
			if generation ~= alarmGeneration then
				return
			end

			cancelAlarm = nil
			armedDeadline = nil
			waking = true
			-- A callback may register another already-due deadline. Give it a new
			-- scheduler turn rather than spinning inside the current wakeup.
			local watermark: number = nextOrdinal

			while heap[1] ~= nil and heap[1].deadline <= now() and heap[1].ordinal <= watermark do
				local entry: Entry = heap[1]
				remove(entry)
				local success: boolean, reason: any = pcall(entry.callback)

				if not success then
					report(tostring(reason))
				end
			end

			waking = false
			arm()
		end)
	end

	return {
		Schedule = function(deadline: number, callback: () -> ()): () -> ()
			assert(Value.IsFinite(deadline), "InvalidGestureDeadline")
			assert(#heap < Constants.MAX_GESTURE_DEADLINES, "InputGestureDeadlineLimitExceeded")
			nextOrdinal += 1
			local entry: Entry = { deadline = deadline, ordinal = nextOrdinal, callback = callback, index = #heap + 1 }
			table.insert(heap, entry)
			up(entry.index)
			arm()

			return function(): ()
				if entry.index > 0 then
					remove(entry)
					arm()
				end
			end
		end,
	}
end

return Scheduler
