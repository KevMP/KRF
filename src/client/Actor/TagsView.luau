--!strict
local Types = require(script.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)
local OwnedSignals = require(script.Parent.Parent.Parent.shared.Signal.OwnedSignals)

local TagsView = {} :: Types.TagsViewModule

-- N6 TDD scaffold. Queries and domain event binding are intentionally inert.
function TagsView.new(_getDomain: () -> Types.DomainView?, _serverTimeNow: (() -> number)?): Types.TagsViewOwner
	local added: SignalTypes.Signal<string> = Signal.new()
	local refreshed: SignalTypes.Signal<string> = Signal.new()
	local removed: SignalTypes.Signal<string> = Signal.new()
	local expired: SignalTypes.Signal<string> = Signal.new()
	local changed: SignalTypes.Signal<Types.DomainChangeSource> = Signal.new()
	local owned: SignalTypes.OwnedSignals = OwnedSignals.new({ added, refreshed, removed, expired, changed })
	local view: Types.TagsView = table.freeze({
		HasTag = function(_self: Types.TagsView, _tagId: string): boolean
			return false
		end,
		GetTag = function(_self: Types.TagsView, _tagId: string): Types.ActiveTagSnapshot?
			return nil
		end,
		GetActiveTags = function(_self: Types.TagsView): { Types.ActiveTagSnapshot }
			return table.freeze({} :: { Types.ActiveTagSnapshot })
		end,
		OnTagAdded = Signal.wrapEvent(added),
		OnTagRefreshed = Signal.wrapEvent(refreshed),
		OnTagRemoved = Signal.wrapEvent(removed),
		OnTagExpired = Signal.wrapEvent(expired),
		OnStateChanged = Signal.wrapEvent(changed),
	})
	return {
		view = view,
		Destroy = function(_self: Types.TagsViewOwner): ()
			owned:Destroy()
		end,
	}
end

return TagsView
