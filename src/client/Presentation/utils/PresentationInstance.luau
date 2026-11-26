--!strict
local Types = require(script.Parent.Parent.types)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local Subscriptions = require(script.Parent.PresentationSubscriptions)

local PresentationInstance = {}

function PresentationInstance.Report(id: string, entry: Types.PresentationEntryEvent, reason: string): ()
	local actorId: string = if entry.actor ~= nil then entry.actor:GetId() else "(none)"

	warn(
		("[Presentation] id=%s source=%s event=%s actor=%s reason=%s"):format(
			id,
			entry.source,
			entry.event,
			actorId,
			reason
		)
	)
end

function PresentationInstance.New(
	definition: Types.PresentationDefinition,
	entry: Types.PresentationEntryEvent,
	environment: Types.PresentationSubscriptionEnvironment,
	release: () -> ()
): Types.PresentationContext
	local active: boolean = true
	local onFinished: (() -> ())? = release
	local cleanups: { () -> () } = {}

	local association: Types.PresentationActionAssociation? = if entry.source == "Action"
		then { actor = entry.actor, actionId = entry.action.actionId, sequenceId = entry.action.sequenceId }
		else nil

	local context: Types.PresentationContext

	local on, disconnectSubscriptions = Subscriptions.New(definition.id, entry, {
		IsActive = function(): boolean
			return active
		end,
		GetActionAssociation = function(): Types.PresentationActionAssociation?
			return association
		end,
		Fail = function(observation: Types.PresentationEntryEvent, reason: string): ()
			context:Finish()
			PresentationInstance.Report(definition.id, observation, reason)
		end,
	}, environment)

	local function runCleanup(cleanup: () -> ()): ()
		local success: boolean, reason: string? = Observers.Run(cleanup)

		if not success then
			PresentationInstance.Report(definition.id, entry, "CleanupFailed:" .. (reason or "Unknown"))
		end
	end

	context = table.freeze({
		entry = entry,
		actor = entry.actor,
		On = on,
		IsActive = function(_self: Types.PresentationContext): boolean
			return active
		end,
		Own = function(_self: Types.PresentationContext, cleanup: () -> ()): ()
			assert(type(cleanup) == "function", "PresentationCleanupInvalid")

			if active then
				table.insert(cleanups, cleanup)
			else
				runCleanup(cleanup)
			end
		end,
		Finish = function(_self: Types.PresentationContext): ()
			if not active then
				return
			end

			active = false
			disconnectSubscriptions()
			local finished: () -> () = assert(onFinished, "Active presentation must own a release callback")
			onFinished = nil
			finished()

			if #cleanups > 0 then
				task.defer(function()
					for index: number = #cleanups, 1, -1 do
						runCleanup(cleanups[index])
					end

					table.clear(cleanups)
				end)
			end
		end,
	})

	-- Record ownership in the runtime before this deferred constructor can run.
	task.defer(function()
		if not active then
			return
		end

		local success: boolean, failure: any = pcall(definition.create, context)

		if not success then
			context:Finish()

			PresentationInstance.Report(
				definition.id,
				entry,
				"CreateFailed:" .. (if type(failure) == "string" then failure else "NonStringError")
			)
		end
	end)

	return context
end

return PresentationInstance
