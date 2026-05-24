--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TagTypes = require(ReplicatedStorage.Packages.KRF.server.Tags.types)

type TagDefinition = TagTypes.TagDefinition

local catalog: { TagDefinition } = {
	{
		id = "Status.Rooted",
		duplicateBehavior = "Ignore",
		visibility = "ServerOnly",
	},
	{
		id = "Status.Stunned",
		defaultDuration = 1.5,
		duplicateBehavior = "Refresh",
		visibility = "ClientVisible",
	},
	{
		id = "Buff.Sprint",
		defaultDuration = 6,
		duplicateBehavior = "Stack",
		maxStacks = 3,
		visibility = "ClientVisible",
	},
}

return catalog
