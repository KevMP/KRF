--!strict
local Types = require(script.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)
local DomainBinding = require(script.Parent.utils.TypedDomainBinding)
local OwnedSignals = require(script.Parent.Parent.Parent.shared.Signal.OwnedSignals)

local ActionsView = {} :: Types.ActionsViewModule
type State = { [number]: string }

local function snapshot(actionId: string, sequenceId: number): Types.ActionSnapshot
	return table.freeze({ actionId = actionId, sequenceId = sequenceId })
end

function ActionsView.new(getDomain: () -> Types.DomainView?): Types.ActionsViewOwner
	local destroyed: boolean = false
	local changed: SignalTypes.Signal<Types.DomainChangeSource> = Signal.new()
	local started: SignalTypes.Signal<Types.ActionSnapshot> = Signal.new()
	local ended: SignalTypes.Signal<Types.ActionSnapshot> = Signal.new()
	local interrupted: SignalTypes.Signal<Types.ActionSnapshot> = Signal.new()
	local owned: SignalTypes.OwnedSignals = OwnedSignals.new({ changed, started, ended, interrupted })

	local bindDomain, disconnectDomain = DomainBinding.new(getDomain, function(domain, isCurrent, connections)
		DomainBinding.Relay(domain, "Started", started, isCurrent, connections, owned)
		DomainBinding.Relay(domain, "Ended", ended, isCurrent, connections, owned)
		DomainBinding.Relay(domain, "Interrupted", interrupted, isCurrent, connections, owned)

		table.insert(
			connections,
			domain.OnChanged:Connect(function(change: Types.DomainChange)
				if isCurrent() then
					owned:WithDeferredDestroy(function()
						changed:Fire(change.source)
					end)
				end
			end)
		)
	end)

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
		OnActionStarted = Signal.wrapEvent(started),
		OnActionEnded = Signal.wrapEvent(ended),
		OnActionInterrupted = Signal.wrapEvent(interrupted),
		OnStateChanged = Signal.wrapEvent(changed),
	})

	return {
		view = view,
		BindDomain = function(_self: Types.ActionsViewOwner): ()
			bindDomain()
		end,
		Destroy = function(_self: Types.ActionsViewOwner): ()
			if destroyed then
				return
			end

			destroyed = true

			disconnectDomain()

			owned:Destroy()
		end,
	}
end

return ActionsView
