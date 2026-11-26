--!strict
local Types = require(script.Parent.Parent.types)
local Events = require(script.Parent.Parent.PresentationEvents)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local NetworkingTypes = require(script.Parent.Parent.Parent.Networking.types)
local Hints = require(script.Parent.Parent.Parent.Networking.HintRuntime)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)

local known: { [Types.PresentationEventDescriptor]: boolean } = table.freeze({
	[Events.Action.Started] = true,
	[Events.Action.Ended] = true,
	[Events.Action.Interrupted] = true,
	[Events.Tag.Added] = true,
	[Events.Tag.Refreshed] = true,
	[Events.Tag.Removed] = true,
	[Events.Tag.Expired] = true,
	[Events.Resource.Changed] = true,
	[Events.Hint.Received] = true,
})

local Sources = {}

function Sources.IsKnown(descriptor: any): boolean
	return type(descriptor) == "table" and known[descriptor] == true
end

-- Capture only framework metadata here. Entry and follow-up owners decide
-- eligibility and schedule author execution after the source has returned.
function Sources.Connect(
	descriptor: Types.PresentationEventDescriptor,
	actor: ActorTypes.ActorView?,
	deliver: (string, Types.PresentationEntryEvent) -> ()
): SignalTypes.Connection
	if descriptor.source == "Hint" then
		return Hints.OnHintReceived:Connect(function(receipt: NetworkingTypes.HintReceived)
			local observation: Types.HintEntryEvent = table.freeze({
				source = "Hint" :: "Hint",
				event = "Received" :: "Received",
				actor = receipt.actorView,
				hintId = receipt.hintId,
				payload = receipt.payload,
			})

			deliver(receipt.hintId, observation)
		end)
	end

	local scopedActor: ActorTypes.ActorView = assert(actor, "Actor source requires an ActorView")

	if descriptor.source == "Action" then
		local actions: ActorTypes.ActionsView = scopedActor:GetActions()

		local signal: SignalTypes.Event<ActorTypes.ActionSnapshot> = if descriptor.event == "Started"
			then actions.OnActionStarted
			elseif descriptor.event == "Ended" then actions.OnActionEnded
			else actions.OnActionInterrupted

		return signal:Connect(function(snapshot: ActorTypes.ActionSnapshot)
			local observation: Types.ActionEntryEvent = table.freeze({
				source = "Action" :: "Action",
				event = descriptor.event,
				actor = scopedActor,
				action = snapshot,
			})

			deliver(snapshot.actionId, observation)
		end)
	elseif descriptor.source == "Tag" then
		local tags: ActorTypes.TagsView = scopedActor:GetTags()

		local signal: SignalTypes.Event<string> = if descriptor.event == "Added"
			then tags.OnTagAdded
			elseif descriptor.event == "Refreshed" then tags.OnTagRefreshed
			elseif descriptor.event == "Removed" then tags.OnTagRemoved
			else tags.OnTagExpired

		return signal:Connect(function(id: string)
			local observation: Types.TagEntryEvent = table.freeze({
				source = "Tag" :: "Tag",
				event = descriptor.event,
				actor = scopedActor,
				tagId = id,
			})

			deliver(id, observation)
		end)
	else
		return scopedActor:GetResources().OnResourceChanged:Connect(function(change: ActorTypes.ResourceViewChange)
			local observation: Types.ResourceEntryEvent = table.freeze({
				source = "Resource" :: "Resource",
				event = "Changed" :: "Changed",
				actor = scopedActor,
				change = change,
			})

			deliver(change.resourceId, observation)
		end)
	end
end

return table.freeze(Sources)
