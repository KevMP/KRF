--!strict
local Types = require(script.Parent.Parent.types)
local Events = require(script.Parent.Parent.PresentationEvents)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local NetworkingTypes = require(script.Parent.Parent.Parent.Networking.types)
local Hints = require(script.Parent.Parent.Parent.Networking.HintRuntime)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)

type Deliver = (Types.PresentationEventDescriptor, string, Types.PresentationEntryEvent) -> ()

local EntrySources = {}

function EntrySources.ConnectActor(
	catalog: Types.PresentationCatalog,
	actor: ActorTypes.ActorView,
	deliver: Deliver,
	connections: { SignalTypes.Connection }
): ()
	local function action(descriptor: Types.ActionEventDescriptor, signal: SignalTypes.Event<ActorTypes.ActionSnapshot>)
		if catalog[descriptor] == nil then
			return
		end

		table.insert(
			connections,
			signal:Connect(function(snapshot: ActorTypes.ActionSnapshot)
				local entry: Types.ActionEntryEvent = table.freeze({
					source = "Action" :: "Action",
					event = descriptor.event,
					actor = actor,
					action = snapshot,
				})

				deliver(descriptor, snapshot.actionId, entry)
			end)
		)
	end

	local function tag(descriptor: Types.TagEventDescriptor, signal: SignalTypes.Event<string>)
		if catalog[descriptor] == nil then
			return
		end

		table.insert(
			connections,
			signal:Connect(function(id: string)
				local entry: Types.TagEntryEvent =
					table.freeze({ source = "Tag" :: "Tag", event = descriptor.event, actor = actor, tagId = id })

				deliver(descriptor, id, entry)
			end)
		)
	end

	local actions: ActorTypes.ActionsView = actor:GetActions()
	action(Events.Action.Started, actions.OnActionStarted)
	action(Events.Action.Ended, actions.OnActionEnded)
	action(Events.Action.Interrupted, actions.OnActionInterrupted)

	local tags: ActorTypes.TagsView = actor:GetTags()
	tag(Events.Tag.Added, tags.OnTagAdded)
	tag(Events.Tag.Refreshed, tags.OnTagRefreshed)
	tag(Events.Tag.Removed, tags.OnTagRemoved)
	tag(Events.Tag.Expired, tags.OnTagExpired)

	if catalog[Events.Resource.Changed] ~= nil then
		table.insert(
			connections,
			actor:GetResources().OnResourceChanged:Connect(function(change: ActorTypes.ResourceViewChange)
				if change.source == "Commit" then
					local entry: Types.ResourceEntryEvent = table.freeze({
						source = "Resource" :: "Resource",
						event = "Changed" :: "Changed",
						actor = actor,
						change = change,
					})

					deliver(Events.Resource.Changed, change.resourceId, entry)
				end
			end)
		)
	end
end

function EntrySources.ConnectHints(catalog: Types.PresentationCatalog, deliver: Deliver): SignalTypes.Connection?
	if catalog[Events.Hint.Received] == nil then
		return nil
	end

	return Hints.OnHintReceived:Connect(function(receipt: NetworkingTypes.HintReceived)
		local entry: Types.HintEntryEvent = table.freeze({
			source = "Hint" :: "Hint",
			event = "Received" :: "Received",
			actor = receipt.actorView,
			hintId = receipt.hintId,
			payload = receipt.payload,
		})

		deliver(Events.Hint.Received, receipt.hintId, entry)
	end)
end

return EntrySources
