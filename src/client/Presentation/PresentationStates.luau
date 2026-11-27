--!strict
local Types = require(script.Parent.types)

local tagActive: Types.TagActiveDescriptor = table.freeze({ source = "Tag" :: "Tag", state = "Active" :: "Active" })

local actionActive: Types.ActionActiveDescriptor =
	table.freeze({ source = "Action" :: "Action", state = "Active" :: "Active" })

local localPrediction: Types.LocalPredictionDescriptor =
	table.freeze({ source = "Action" :: "Action", state = "LocalPrediction" :: "LocalPrediction" })

local resourceCurrent: Types.ResourceCurrentDescriptor =
	table.freeze({ source = "Resource" :: "Resource", state = "Current" :: "Current" })

local actorModel: Types.ActorModelDescriptor = table.freeze({ source = "Actor" :: "Actor", state = "Model" :: "Model" })

return table.freeze({
	Tag = table.freeze({ Active = tagActive }),
	Action = table.freeze({ Active = actionActive, LocalPrediction = localPrediction }),
	Resource = table.freeze({ Current = resourceCurrent }),
	Actor = table.freeze({ Model = actorModel }),
})
