--!strict
local CommandTimer = {}

function CommandTimer.Schedule(seconds: number, callback: () -> ()): () -> ()
	local fired: boolean = false

	local timer: thread = task.delay(seconds, function(): ()
		fired = true
		callback()
	end)

	return function(): ()
		if not fired and coroutine.status(timer) ~= "dead" then
			task.cancel(timer)
		end
	end
end

return CommandTimer
