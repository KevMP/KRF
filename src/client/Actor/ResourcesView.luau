--!strict
local Types = require(script.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)
local OwnedSignals = require(script.Parent.Parent.Parent.shared.Signal.OwnedSignals)

local ResourcesView = {} :: Types.ResourcesViewModule

-- N7 TDD scaffold. Domain queries, interpolation and state-derived events remain unimplemented.
function ResourcesView.new(
	_getDomain: () -> Types.DomainView?,
	_serverTimeNow: (() -> number)?
): Types.ResourcesViewOwner
	local changed: SignalTypes.Signal<Types.ResourceViewChange> = Signal.new()
	local owned: SignalTypes.OwnedSignals = OwnedSignals.new({ changed })

	local function missing(_self: Types.ResourcesView, _resourceId: string): number?
		return nil
	end

	local view: Types.ResourcesView = table.freeze({
		HasResource = function(_self: Types.ResourcesView, _resourceId: string): boolean
			return false
		end,
		GetResource = function(_self: Types.ResourcesView, _resourceId: string): Types.ResourceSnapshot?
			return nil
		end,
		GetCurrent = missing,
		GetMin = missing,
		GetMax = missing,
		GetRegenRate = missing,
		GetAssignedResources = function(_self: Types.ResourcesView): { Types.ResourceSnapshot }
			return table.freeze({} :: { Types.ResourceSnapshot })
		end,
		OnResourceChanged = Signal.wrapEvent(changed),
	})

	return {
		view = view,
		Destroy = function(_self: Types.ResourcesViewOwner): ()
			owned:Destroy()
		end,
	}
end

return ResourcesView
