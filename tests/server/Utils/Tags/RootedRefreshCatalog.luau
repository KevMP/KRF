local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TagTypes = require(ReplicatedStorage.Packages.KRF.server.Tags.types)

type TagDefinition = TagTypes.TagDefinition

local catalog: { TagDefinition } = {
	{
		id = "Status.RootedRefresh",
		duplicateBehavior = "Refresh",
		visibility = "ServerOnly",
	},
}

return catalog
