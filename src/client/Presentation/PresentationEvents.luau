--!strict
local Types = require(script.Parent.types)

local function action(event: Types.ActionEventKind): Types.ActionEventDescriptor
	return table.freeze({ source = "Action" :: "Action", event = event })
end

local function tag(event: Types.TagEventKind): Types.TagEventDescriptor
	return table.freeze({ source = "Tag" :: "Tag", event = event })
end

local resourceChanged: Types.ResourceEventDescriptor =
	table.freeze({ source = "Resource" :: "Resource", event = "Changed" :: "Changed" })

local hintReceived: Types.HintEventDescriptor =
	table.freeze({ source = "Hint" :: "Hint", event = "Received" :: "Received" })

return table.freeze({
	Action = table.freeze({
		Started = action("Started"),
		Ended = action("Ended"),
		Interrupted = action("Interrupted"),
	}),
	Tag = table.freeze({
		Added = tag("Added"),
		Refreshed = tag("Refreshed"),
		Removed = tag("Removed"),
		Expired = tag("Expired"),
	}),
	Resource = table.freeze({ Changed = resourceChanged }),
	Hint = table.freeze({ Received = hintReceived }),
})
