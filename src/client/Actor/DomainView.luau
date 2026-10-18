--!strict
local Types = require(script.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)
local OwnedSignals = require(script.Parent.Parent.Parent.shared.Signal.OwnedSignals)

-- Owns current immutable state, OnChanged, declared events and owned-signal
-- teardown. Schema validation/patching belongs to ActorStatePlan. State install
-- and notification are separate so Networking can publish a whole Actor atomically.
local DomainView = {} :: Types.DomainViewModule

function DomainView.new(domainId: string, immutableState: any, eventIds: { string }): (Types.DomainViewOwner?, string?)
	local current: any = immutableState
	local destroyed: boolean = false
	local changed: SignalTypes.Signal<Types.DomainChange> = Signal.new()
	local signals: { OwnedSignals.OwnedSignal } = { changed }
	local events: { [string]: SignalTypes.Event<any> } = {}
	local writableEvents: { [string]: SignalTypes.Signal<any> } = {}
	for _, eventId: string in eventIds do
		local signal: SignalTypes.Signal<any> = Signal.new()
		writableEvents[eventId] = signal
		events[eventId] = Signal.wrapEvent(signal)
		table.insert(signals, signal)
	end
	local owned: SignalTypes.OwnedSignals = OwnedSignals.new(signals)
	local view: Types.DomainView = table.freeze({
		GetId = function(_self: Types.DomainView): string
			return domainId
		end,
		GetState = function(_self: Types.DomainView): any
			return current
		end,
		GetEvent = function(_self: Types.DomainView, eventId: string): SignalTypes.Event<any>?
			return if destroyed then nil else events[eventId]
		end,
		OnChanged = Signal.wrapEvent(changed),
	})
	return {
		view = view,
		InstallState = function(_self: Types.DomainViewOwner, state: any): ()
			assert(not destroyed, "DomainViewDestroyed")
			current = state
		end,
		NotifyChanged = function(_self: Types.DomainViewOwner, change: Types.DomainChange): ()
			if not destroyed then
				owned:WithDeferredDestroy(function()
					changed:Fire(change)
				end)
			end
		end,
		FireEvent = function(_self: Types.DomainViewOwner, eventId: string, payload: any): ()
			if not destroyed then
				local signal: SignalTypes.Signal<any>? = writableEvents[eventId]
				assert(signal ~= nil, "UndeclaredDomainEvent")
				owned:WithDeferredDestroy(function()
					signal:Fire(payload)
				end)
			end
		end,
		Destroy = function(_self: Types.DomainViewOwner): ()
			if destroyed then
				return
			end
			destroyed = true
			current = nil
			table.clear(events)
			table.clear(writableEvents)
			owned:Destroy()
		end,
	},
		nil
end

return DomainView
