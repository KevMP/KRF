--!strict
local Types = require(script.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)
local OwnedSignals = require(script.Parent.Parent.Parent.shared.Signal.OwnedSignals)

local ResourcesView = {} :: Types.ResourcesViewModule
local Workspace: Workspace = game:GetService("Workspace")

type ResourceAnchor = {
	read anchorValue: number,
	read anchorTime: number,
	read min: number,
	read max: number,
	read regenRate: number?,
}

type ResourceState = { [string]: ResourceAnchor }

local function current(entry: ResourceAnchor, queryTime: number): number
	local rate: number? = entry.regenRate
	local value: number = entry.anchorValue

	if rate ~= nil and rate > 0 then
		value += rate * (queryTime - entry.anchorTime)
	end

	return math.clamp(value, entry.min, entry.max)
end

local function snapshot(id: string, entry: ResourceAnchor, queryTime: number): Types.ResourceSnapshot
	return table.freeze({
		resourceId = id,
		current = current(entry, queryTime),
		min = entry.min,
		max = entry.max,
		regenRate = entry.regenRate,
	})
end

local function equal(first: ResourceAnchor?, second: ResourceAnchor?): boolean
	return first == second
		or (
			first ~= nil
			and second ~= nil
			and first.anchorValue == second.anchorValue
			and first.anchorTime == second.anchorTime
			and first.min == second.min
			and first.max == second.max
			and first.regenRate == second.regenRate
		)
end

function ResourcesView.new(getDomain: () -> Types.DomainView?, serverTimeNow: (() -> number)?): Types.ResourcesViewOwner
	local destroyed: boolean = false

	local now: () -> number = serverTimeNow or function(): number
		return Workspace:GetServerTimeNow()
	end

	local changed: SignalTypes.Signal<Types.ResourceViewChange> = Signal.new()
	local owned: SignalTypes.OwnedSignals = OwnedSignals.new({ changed })

	local function state(): ResourceState?
		if destroyed then
			return nil
		end

		local domain: Types.DomainView? = getDomain()

		return if domain ~= nil then domain:GetState() else nil
	end

	local function entryFor(id: string): ResourceAnchor?
		local entries: ResourceState? = state()

		return if entries ~= nil then entries[id] else nil
	end

	local domain: Types.DomainView? = getDomain()

	local function onDomainChanged(change: Types.DomainChange): ()
		if destroyed then
			return
		end

		local previous: ResourceState = change.previous or {}
		local nextState: ResourceState = change.current or {}
		local ids: { string } = {}

		for id: string, entry: ResourceAnchor in previous do
			if not equal(entry, nextState[id]) then
				table.insert(ids, id)
			end
		end

		for id: string in nextState do
			if previous[id] == nil then
				table.insert(ids, id)
			end
		end

		if #ids == 0 then
			return
		end

		table.sort(ids)
		local queryTime: number = now()
		local changes: { Types.ResourceViewChange } = {}

		for _, id: string in ids do
			local old: ResourceAnchor? = previous[id]
			local latest: ResourceAnchor? = nextState[id]

			table.insert(
				changes,
				table.freeze({
					resourceId = id,
					previous = if old ~= nil then snapshot(id, old, queryTime) else nil,
					current = if latest ~= nil then snapshot(id, latest, queryTime) else nil,
					source = change.source,
				})
			)
		end

		owned:WithDeferredDestroy(function(): ()
			for _, resourceChange: Types.ResourceViewChange in changes do
				if destroyed then
					break
				end

				changed:Fire(resourceChange)
			end
		end)
	end

	local connection: SignalTypes.Connection? = if domain ~= nil then domain.OnChanged:Connect(onDomainChanged) else nil

	local view: Types.ResourcesView = table.freeze({
		HasResource = function(_self: Types.ResourcesView, resourceId: string): boolean
			return entryFor(resourceId) ~= nil
		end,
		GetResource = function(_self: Types.ResourcesView, resourceId: string): Types.ResourceSnapshot?
			local entry: ResourceAnchor? = entryFor(resourceId)

			return if entry ~= nil then snapshot(resourceId, entry, now()) else nil
		end,
		GetCurrent = function(_self: Types.ResourcesView, resourceId: string): number?
			local entry: ResourceAnchor? = entryFor(resourceId)

			return if entry ~= nil then current(entry, now()) else nil
		end,
		GetMin = function(_self: Types.ResourcesView, resourceId: string): number?
			local entry: ResourceAnchor? = entryFor(resourceId)

			return if entry ~= nil then entry.min else nil
		end,
		GetMax = function(_self: Types.ResourcesView, resourceId: string): number?
			local entry: ResourceAnchor? = entryFor(resourceId)

			return if entry ~= nil then entry.max else nil
		end,
		GetRegenRate = function(_self: Types.ResourcesView, resourceId: string): number?
			local entry: ResourceAnchor? = entryFor(resourceId)

			return if entry ~= nil then entry.regenRate else nil
		end,
		GetAssignedResources = function(_self: Types.ResourcesView): { Types.ResourceSnapshot }
			local entries: ResourceState? = state()
			local assigned: { Types.ResourceSnapshot } = {}

			if entries ~= nil and next(entries) ~= nil then
				local queryTime: number = now()

				for id: string, entry: ResourceAnchor in entries do
					table.insert(assigned, snapshot(id, entry, queryTime))
				end
			end

			table.sort(assigned, function(first: Types.ResourceSnapshot, second: Types.ResourceSnapshot): boolean
				return first.resourceId < second.resourceId
			end)

			return table.freeze(assigned)
		end,
		OnResourceChanged = Signal.wrapEvent(changed),
	})

	return {
		view = view,
		Destroy = function(_self: Types.ResourcesViewOwner): ()
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

return ResourcesView
