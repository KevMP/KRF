--!strict
type Timer = { at: number, callback: () -> (), active: boolean }

local TestClock = {}

function TestClock.new(start: number?)
	local now: number = start or 0
	local timers: { Timer } = {}

	return {
		Now = function(): number
			return now
		end,
		Schedule = function(seconds: number, callback: () -> ()): () -> ()
			assert(seconds >= 0 and seconds < math.huge, "Expected finite timer")
			local timer: Timer = { at = now + seconds, callback = callback, active = true }
			table.insert(timers, timer)

			return function(): ()
				timer.active = false
			end
		end,
		Advance = function(seconds: number): ()
			local finish: number = now + seconds

			while true do
				local nextTimer: Timer? = nil

				for _, timer: Timer in timers do
					if timer.active and timer.at <= finish and (nextTimer == nil or timer.at < nextTimer.at) then
						nextTimer = timer
					end
				end

				if nextTimer == nil then
					break
				end

				now = nextTimer.at
				nextTimer.active = false
				nextTimer.callback()
			end

			now = finish
		end,
		Count = function(): number
			local count: number = 0

			for _, timer: Timer in timers do
				if timer.active then
					count += 1
				end
			end

			return count
		end,
	}
end

return TestClock
