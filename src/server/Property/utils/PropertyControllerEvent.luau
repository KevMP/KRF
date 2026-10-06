--!strict
local serverFolder = script.Parent.Parent.Parent
local SignalFolder = serverFolder.Parent.shared.Signal

local ActorTypes = require(serverFolder.Actor.types)
local PropertyTypes = require(serverFolder.Property.types)
local SignalTypes = require(SignalFolder.types)

export type PropertyControllerEventContext = {
	actor: ActorTypes.Actor,
	ownedSignals: SignalTypes.OwnedSignals,
	basePropertyChangedSignal: SignalTypes.Signal<ActorTypes.Actor, string, number?, number>,
	resolvedPropertyChangedSignal: SignalTypes.Signal<ActorTypes.Actor, string, number?, number>,
	propertyChangedSignal: SignalTypes.Signal<PropertyTypes.PropertyChange>,
}

export type PropertyEventJournal = {
	Queue: (
		self: PropertyEventJournal,
		change: PropertyTypes.PropertyChange,
		baseChanged: boolean,
		resolvedChanged: boolean
	) -> (),
	Drain: (self: PropertyEventJournal) -> (),
	Destroy: (self: PropertyEventJournal) -> (),
}

type NotificationGroup = { started: boolean, allowed: boolean }
type Emission = { group: NotificationGroup, fire: () -> () }

local PropertyControllerEventUtils = {}

function PropertyControllerEventUtils.new(eventContext: PropertyControllerEventContext): PropertyEventJournal
	local journal: PropertyEventJournal = {} :: PropertyEventJournal
	local pending: { [number]: Emission } = {}
	local head: number = 1
	local tail: number = 0
	local drainDepth: number = 0
	local destroyed: boolean = false

	function journal:Queue(change: PropertyTypes.PropertyChange, baseChanged: boolean, resolvedChanged: boolean): ()
		local group: NotificationGroup = { started = false, allowed = false }
		local function enqueue(fire: () -> ()): ()
			tail += 1
			pending[tail] = { group = group, fire = fire }
		end
		if baseChanged then
			enqueue(function()
				eventContext.basePropertyChangedSignal:Fire(
					eventContext.actor,
					change.propertyName,
					change.oldBaseValue,
					change.newBaseValue
				)
			end)
		end
		if resolvedChanged then
			enqueue(function()
				eventContext.resolvedPropertyChangedSignal:Fire(
					eventContext.actor,
					change.propertyName,
					change.oldResolvedValue,
					change.newResolvedValue
				)
			end)
		end
		enqueue(function()
			eventContext.propertyChangedSignal:Fire(change)
		end)
	end

	function journal:Drain(): ()
		if head > tail then
			return
		end
		drainDepth += 1
		eventContext.ownedSignals:WithDeferredDestroy(function()
			while head <= tail do
				local emission: Emission = pending[head]
				pending[head] = nil
				head += 1
				local group: NotificationGroup = emission.group
				if not group.started then
					group.started = true
					group.allowed = not destroyed
				end
				if group.allowed then
					emission.fire()
				end
			end
		end)
		drainDepth -= 1
		if drainDepth == 0 then
			head = 1
			tail = 0
		end
	end

	function journal:Destroy(): ()
		destroyed = true
		if drainDepth == 0 then
			table.clear(pending)
			head = 1
			tail = 0
		end
	end

	return journal
end

return PropertyControllerEventUtils
