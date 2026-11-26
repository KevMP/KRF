--!strict
local Types = require(script.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)
local DomainBinding = require(script.Parent.utils.TypedDomainBinding)
local OwnedSignals = require(script.Parent.Parent.Parent.shared.Signal.OwnedSignals)

local TagsView = {} :: Types.TagsViewModule
local Workspace: Workspace = game:GetService("Workspace")

type ReplicatedTagState = { read stackCount: number, read expiresAt: number? }
type ReplicatedTagsState = { [string]: ReplicatedTagState }

function TagsView.new(getDomain: () -> Types.DomainView?, serverTimeNow: (() -> number)?): Types.TagsViewOwner
	local destroyed: boolean = false

	local now: () -> number = serverTimeNow or function(): number
		return Workspace:GetServerTimeNow()
	end

	local changed: SignalTypes.Signal<Types.DomainChangeSource> = Signal.new()
	local added: SignalTypes.Signal<string> = Signal.new()
	local refreshed: SignalTypes.Signal<string> = Signal.new()
	local removed: SignalTypes.Signal<string> = Signal.new()
	local expired: SignalTypes.Signal<string> = Signal.new()
	local owned: SignalTypes.OwnedSignals = OwnedSignals.new({ changed, added, refreshed, removed, expired })

	local bindDomain, disconnectDomain = DomainBinding.new(getDomain, function(domain, isCurrent, connections)
		DomainBinding.Relay(domain, "Added", added, isCurrent, connections, owned)
		DomainBinding.Relay(domain, "Refreshed", refreshed, isCurrent, connections, owned)
		DomainBinding.Relay(domain, "Removed", removed, isCurrent, connections, owned)
		DomainBinding.Relay(domain, "Expired", expired, isCurrent, connections, owned)

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
		OnTagAdded = Signal.wrapEvent(added),
		OnTagRefreshed = Signal.wrapEvent(refreshed),
		OnTagRemoved = Signal.wrapEvent(removed),
		OnTagExpired = Signal.wrapEvent(expired),
		OnStateChanged = Signal.wrapEvent(changed),
	})

	return {
		view = view,
		BindDomain = function(_self: Types.TagsViewOwner): ()
			bindDomain()
		end,
		Destroy = function(_self: Types.TagsViewOwner): ()
			if destroyed then
				return
			end

			destroyed = true

			disconnectDomain()

			owned:Destroy()
		end,
	}
end

return TagsView
