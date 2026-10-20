--!strict
local Types = require(script.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)
local OwnedSignals = require(script.Parent.Parent.Parent.shared.Signal.OwnedSignals)

local ActionsView = {} :: Types.ActionsViewModule
type State = { [number]: string }

local function snapshot(actionId: string, sequenceId: number): Types.ActionSnapshot
	return table.freeze({ actionId = actionId, sequenceId = sequenceId })
end

function ActionsView.new(getDomain: () -> Types.DomainView?): Types.ActionsViewOwner
	local destroyed: boolean = false
	local domain: Types.DomainView? = getDomain()
	local changed: SignalTypes.Signal<Types.DomainChangeSource> = Signal.new()
	local signals: { OwnedSignals.OwnedSignal } = { changed }

	local function semanticEvent(id: string): SignalTypes.Event<Types.ActionSnapshot>
		if domain ~= nil then
			local event: SignalTypes.Event<Types.ActionSnapshot>? = domain:GetEvent(id)
			assert(event ~= nil, "ActionsViewMissingDomainEvent:" .. id)

			return event
		end

		local signal: SignalTypes.Signal<Types.ActionSnapshot> = Signal.new()
		table.insert(signals, signal)

		return Signal.wrapEvent(signal)
	end

	local started: SignalTypes.Event<Types.ActionSnapshot> = semanticEvent("Started")
	local ended: SignalTypes.Event<Types.ActionSnapshot> = semanticEvent("Ended")
	local interrupted: SignalTypes.Event<Types.ActionSnapshot> = semanticEvent("Interrupted")
	local owned: SignalTypes.OwnedSignals = OwnedSignals.new(signals)

	local connection: SignalTypes.Connection? = if domain ~= nil
		then domain.OnChanged:Connect(function(change: Types.DomainChange): ()
			if not destroyed then
				owned:WithDeferredDestroy(function(): ()
					changed:Fire(change.source)
				end)
			end
		end)
		else nil

	local function state(): State?
		if destroyed then
			return nil
		end

		local current: Types.DomainView? = getDomain()

		return if current ~= nil then current:GetState() else nil
	end

	local view: Types.ActionsView = table.freeze({
		IsActionActive = function(_self: Types.ActionsView, actionId: string): boolean
			local current: State? = state()

			if current ~= nil then
				for _, activeId: string in current do
					if activeId == actionId then
						return true
					end
				end
			end

			return false
		end,
		GetAction = function(_self: Types.ActionsView, sequenceId: number): Types.ActionSnapshot?
			local current: State? = state()
			local actionId: string? = if current ~= nil then current[sequenceId] else nil

			return if actionId ~= nil then snapshot(actionId, sequenceId) else nil
		end,
		GetActiveActions = function(_self: Types.ActionsView): { Types.ActionSnapshot }
			local current: State? = state()
			local snapshots: { Types.ActionSnapshot } = {}

			if current ~= nil then
				for sequenceId: number, actionId: string in current do
					table.insert(snapshots, snapshot(actionId, sequenceId))
				end
			end

			table.sort(snapshots, function(left: Types.ActionSnapshot, right: Types.ActionSnapshot): boolean
				return left.sequenceId < right.sequenceId
			end)

			return table.freeze(snapshots)
		end,
		OnActionStarted = started,
		OnActionEnded = ended,
		OnActionInterrupted = interrupted,
		OnStateChanged = Signal.wrapEvent(changed),
	})

	return {
		view = view,
		Destroy = function(_self: Types.ActionsViewOwner): ()
			if destroyed then
				return
			end

			destroyed = true

			if connection ~= nil then
				connection:Disconnect()
			end

			owned:Destroy()
		end,
	}
end

return ActionsView
