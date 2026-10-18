--!strict
local Types = require(script.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)
local OwnedSignals = require(script.Parent.Parent.Parent.shared.Signal.OwnedSignals)

local TagsView = {} :: Types.TagsViewModule
local Workspace: Workspace = game:GetService("Workspace")

type ReplicatedTagState = { read stackCount: number, read expiresAt: number? }
type ReplicatedTagsState = { [string]: ReplicatedTagState }

function TagsView.new(getDomain: () -> Types.DomainView?, serverTimeNow: (() -> number)?): Types.TagsViewOwner
	local destroyed: boolean = false
	local domain: Types.DomainView? = getDomain()
	local now: () -> number = serverTimeNow or function(): number
		return Workspace:GetServerTimeNow()
	end
	local changed: SignalTypes.Signal<Types.DomainChangeSource> = Signal.new()
	local signals: { OwnedSignals.OwnedSignal } = { changed }
	local function semanticEvent(id: string): SignalTypes.Event<string>
		if domain ~= nil then
			local event: SignalTypes.Event<string>? = domain:GetEvent(id)
			assert(event ~= nil, "TagsViewMissingDomainEvent:" .. id)
			return event
		end
		local signal: SignalTypes.Signal<string> = Signal.new()
		table.insert(signals, signal)
		return Signal.wrapEvent(signal)
	end
	local added: SignalTypes.Event<string> = semanticEvent("Added")
	local refreshed: SignalTypes.Event<string> = semanticEvent("Refreshed")
	local removed: SignalTypes.Event<string> = semanticEvent("Removed")
	local expired: SignalTypes.Event<string> = semanticEvent("Expired")
	local owned: SignalTypes.OwnedSignals = OwnedSignals.new(signals)
	local connection: SignalTypes.Connection? = if domain ~= nil
		then domain.OnChanged:Connect(function(change: Types.DomainChange)
			if not destroyed then
				owned:WithDeferredDestroy(function(): ()
					changed:Fire(change.source)
				end)
			end
		end)
		else nil
	local function state(): ReplicatedTagsState?
		if destroyed then
			return nil
		end
		local current: Types.DomainView? = getDomain()
		return if current ~= nil then current:GetState() else nil
	end
	local function snapshot(id: string, entry: ReplicatedTagState, queryTime: number?): Types.ActiveTagSnapshot
		local expiresAt: number? = entry.expiresAt
		return table.freeze({
			tagId = id,
			stackCount = entry.stackCount,
			remainingDuration = if expiresAt ~= nil then math.max(0, expiresAt - (queryTime :: number)) else nil,
		})
	end
	local view: Types.TagsView = table.freeze({
		HasTag = function(_self: Types.TagsView, tagId: string): boolean
			local current: ReplicatedTagsState? = state()
			return current ~= nil and current[tagId] ~= nil
		end,
		GetTag = function(_self: Types.TagsView, tagId: string): Types.ActiveTagSnapshot?
			local current: ReplicatedTagsState? = state()
			local entry: ReplicatedTagState? = if current ~= nil then current[tagId] else nil
			return if entry ~= nil then snapshot(tagId, entry, if entry.expiresAt ~= nil then now() else nil) else nil
		end,
		GetActiveTags = function(_self: Types.TagsView): { Types.ActiveTagSnapshot }
			local current: ReplicatedTagsState? = state()
			local snapshots: { Types.ActiveTagSnapshot } = {}
			local queryTime: number? = nil
			if current ~= nil then
				for id: string, entry: ReplicatedTagState in current do
					if entry.expiresAt ~= nil and queryTime == nil then
						queryTime = now()
					end
					table.insert(snapshots, snapshot(id, entry, queryTime))
				end
			end
			table.sort(snapshots, function(first: Types.ActiveTagSnapshot, second: Types.ActiveTagSnapshot): boolean
				return first.tagId < second.tagId
			end)
			return table.freeze(snapshots)
		end,
		OnTagAdded = added,
		OnTagRefreshed = refreshed,
		OnTagRemoved = removed,
		OnTagExpired = expired,
		OnStateChanged = Signal.wrapEvent(changed),
	})
	return {
		view = view,
		Destroy = function(_self: Types.TagsViewOwner): ()
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

return TagsView
