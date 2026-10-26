--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.DiagnosticConstants)
local Warnings = {}

type Window = { started: number, emitted: number, suppressed: number }

function Warnings.new(options: Types.DiagnosticWarningOptions?)
	local settings: Types.DiagnosticWarningOptions = options or {}
	local now = settings.Now or os.clock
	local seconds = settings.windowSeconds or Constants.WARNING_WINDOW_SECONDS
	local maximum = settings.maxPerWindow or Constants.WARNINGS_PER_WINDOW
	assert(seconds > 0 and seconds < math.huge, "InvalidWarningWindow")
	assert(maximum >= 1 and maximum < math.huge and maximum % 1 == 0, "InvalidWarningLimit")
	local windows: { [Types.DiagnosticWarning]: Window } = {}
	local active = true

	return {
		Allow = function(category: Types.DiagnosticWarning): (boolean, number)
			if not active then
				return false, 0
			end

			local current = now()
			local window = windows[category]
			local suppressed = 0

			if window == nil or current - window.started >= seconds then
				suppressed = if window ~= nil then window.suppressed else 0
				window = { started = current, emitted = 0, suppressed = 0 }
				windows[category] = window
			end

			if window.emitted >= maximum then
				window.suppressed = math.min(9007199254740991, window.suppressed + 1)

				return false, 0
			end

			window.emitted += 1

			return true, suppressed
		end,
		Destroy = function(): ()
			active = false
			table.clear(windows)
		end,
	}
end

function Warnings.Emit(category: Types.DiagnosticWarning, reason: string?, suppressed: number): ()
	warn(
		"[Networking] "
			.. category
			.. (if reason ~= nil then ": " .. reason else "")
			.. (if suppressed > 0 then " (suppressed " .. tostring(suppressed) .. " repeats)" else "")
	)
end

return Warnings
