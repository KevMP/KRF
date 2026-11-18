--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local function Focus(): KRF.ActionDefinition
	return {
		id = "Focus",
		visibility = "ClientVisible",
		autoGrant = true,
		blockedTags = { "Focused" },
		activeTags = { "Focused" },
		onStopRequested = function(context: KRF.ActionExecutionContext): ()
			context:End()
		end,
	}
end

return Focus
