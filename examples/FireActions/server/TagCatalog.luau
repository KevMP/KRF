--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Packages.KRF.server.Tags.types)

local tags: { Types.TagDefinition } = {
	{ id = "Burning", visibility = "ClientVisible", duplicateBehavior = "Refresh", defaultDuration = 3 },
	{ id = "Stunned", visibility = "ClientVisible", duplicateBehavior = "Refresh", defaultDuration = 1.5 },
	{ id = "BreathingFire", visibility = "ClientVisible", duplicateBehavior = "Ignore" },
}

return tags
