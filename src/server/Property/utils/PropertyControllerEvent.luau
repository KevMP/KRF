--!strict
local serverFolder = script.Parent.Parent.Parent
local SignalFolder = serverFolder.Parent.shared.Signal

local ActorTypes = require(serverFolder.Actor.types)
local PropertyTypes = require(serverFolder.Property.types)
local SignalTypes = require(SignalFolder.types)
local PropertyRecompute = require(serverFolder.Property.utils.PropertyRecompute)

export type PropertyControllerEventContext = {
	actor: ActorTypes.Actor,
	ownedSignals: SignalTypes.OwnedSignals,
	basePropertyChangedSignal: SignalTypes.Signal<ActorTypes.Actor, string, number?, number>,
	resolvedPropertyChangedSignal: SignalTypes.Signal<ActorTypes.Actor, string, number?, number>,
	propertyChangedSignal: SignalTypes.Signal<PropertyTypes.PropertyChange>,
}

local PropertyControllerEventUtils = {}

function PropertyControllerEventUtils.FirePropertyChangedWithoutDeferred(
	eventContext: PropertyControllerEventContext,
	propertyName: string,
	oldBaseValue: number?,
	newBaseValue: number,
	oldResolvedValue: number?,
	newResolvedValue: number,
	shouldFireBaseChanged: boolean,
	shouldFireResolvedChanged: boolean
): ()
	if shouldFireBaseChanged then
		eventContext.basePropertyChangedSignal:Fire(eventContext.actor, propertyName, oldBaseValue, newBaseValue)
	end

	if shouldFireResolvedChanged then
		eventContext.resolvedPropertyChangedSignal:Fire(
			eventContext.actor,
			propertyName,
			oldResolvedValue,
			newResolvedValue
		)
	end

	eventContext.propertyChangedSignal:Fire({
		actor = eventContext.actor,
		propertyName = propertyName,
		oldBaseValue = oldBaseValue,
		newBaseValue = newBaseValue,
		oldResolvedValue = oldResolvedValue,
		newResolvedValue = newResolvedValue,
	})
end

function PropertyControllerEventUtils.FirePropertyChanged(
	eventContext: PropertyControllerEventContext,
	propertyName: string,
	oldBaseValue: number?,
	newBaseValue: number,
	oldResolvedValue: number?,
	newResolvedValue: number,
	shouldFireBaseChanged: boolean,
	shouldFireResolvedChanged: boolean
): ()
	eventContext.ownedSignals:WithDeferredDestroy(function()
		PropertyControllerEventUtils.FirePropertyChangedWithoutDeferred(
			eventContext,
			propertyName,
			oldBaseValue,
			newBaseValue,
			oldResolvedValue,
			newResolvedValue,
			shouldFireBaseChanged,
			shouldFireResolvedChanged
		)
	end)
end

function PropertyControllerEventUtils.FireResolvedChangeWithoutDeferred(
	eventContext: PropertyControllerEventContext,
	change: PropertyRecompute.ResolvedChange
): ()
	PropertyControllerEventUtils.FirePropertyChangedWithoutDeferred(
		eventContext,
		change.propertyName,
		change.oldBaseValue,
		change.newBaseValue,
		change.oldResolvedValue,
		change.newResolvedValue,
		false,
		true
	)
end

function PropertyControllerEventUtils.FireResolvedChanges(
	eventContext: PropertyControllerEventContext,
	changes: { PropertyRecompute.ResolvedChange },
	shouldContinue: () -> boolean
): ()
	if #changes == 0 then
		return
	end

	eventContext.ownedSignals:WithDeferredDestroy(function()
		for _, change: PropertyRecompute.ResolvedChange in changes do
			if shouldContinue ~= nil and not shouldContinue() then
				break
			end

			PropertyControllerEventUtils.FireResolvedChangeWithoutDeferred(eventContext, change)
		end
	end)
end

return PropertyControllerEventUtils
