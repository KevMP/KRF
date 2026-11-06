--!strict
local Validation = require(script.Parent.InputRecognitionValidation)

export type Owner = {
	Arm: (due: number) -> (),
	Cancel: () -> (),
}

local Timer = {}

-- Owns one re-armable deadline; a replaced or cancelled alarm can never fire.
function Timer.new(schedule: (number, () -> ()) -> () -> (), onDue: () -> ()): Owner
	local armedAt: number? = nil
	local cancel: (() -> ())? = nil
	local revision: number = 0

	local function stop(): ()
		armedAt = nil
		revision += 1

		if cancel ~= nil then
			cancel()
			cancel = nil
		end
	end

	return {
		Arm = function(due: number): ()
			if armedAt == due and cancel ~= nil then
				return
			end

			stop()
			armedAt = due

			local armed: number = revision

			cancel = schedule(Validation.After(due), function(): ()
				if revision ~= armed then
					return
				end

				cancel = nil
				armedAt = nil
				onDue()
			end)
		end,
		Cancel = stop,
	}
end

return Timer
