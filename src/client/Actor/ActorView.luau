--!strict
local Types = require(script.Parent.types)
local TagsView = require(script.Parent.TagsView)
local ResourcesView = require(script.Parent.ResourcesView)
local ActionsView = require(script.Parent.ActionsView)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local Signal = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)
local OwnedSignals = require(script.Parent.Parent.Parent.shared.Signal.OwnedSignals)

-- Owns identity, Model, visible DomainView membership and Actor-level signals.
-- The returned private owner controls the immutable public view. Install methods
-- never notify; ActorViewRuntime coordinates publication across all owners.
local ActorView = {} :: Types.ActorViewModule

function ActorView.new(
	actorId: string,
	model: Model?,
	domains: { [string]: Types.DomainViewOwner }
): (Types.ActorViewOwner?, string?)
	local currentModel: Model? = model
	local currentDomains: { [string]: Types.DomainViewOwner } = table.clone(domains)
	local domainIds: { string } = {}
	local destroyed: boolean = false
	local available: boolean = true
	local changed: SignalTypes.Signal<Model?, Model?> = Signal.new()
	local domainsChanged: SignalTypes.Signal<Types.DomainMembershipChange> = Signal.new()
	local unavailable: SignalTypes.Signal<> = Signal.new()
	local owned: SignalTypes.OwnedSignals = OwnedSignals.new({ changed, domainsChanged, unavailable })

	local function updateDomainIds(): ()
		domainIds = {}

		for id: string in currentDomains do
			table.insert(domainIds, id)
		end

		table.sort(domainIds)
		table.freeze(domainIds)
	end

	updateDomainIds()

	local tags: Types.TagsViewOwner = TagsView.new(function(): Types.DomainView?
		local domain: Types.DomainViewOwner? = currentDomains["KRF.Tags"]

		return if domain ~= nil then domain.view else nil
	end)

	local resources: Types.ResourcesViewOwner = ResourcesView.new(function(): Types.DomainView?
		local domain: Types.DomainViewOwner? = currentDomains["KRF.Resources"]

		return if domain ~= nil then domain.view else nil
	end)

	local actions: Types.ActionsViewOwner = ActionsView.new(function(): Types.DomainView?
		local domain: Types.DomainViewOwner? = currentDomains["KRF.Actions"]

		return if domain ~= nil then domain.view else nil
	end)

	local view: Types.ActorView = table.freeze({
		GetActions = function(_self: Types.ActorView): Types.ActionsView
			return actions.view
		end,
		GetResources = function(_self: Types.ActorView): Types.ResourcesView
			return resources.view
		end,
		GetTags = function(_self: Types.ActorView): Types.TagsView
			return tags.view
		end,
		GetId = function(_self: Types.ActorView): string
			return actorId
		end,
		GetModel = function(_self: Types.ActorView): Model?
			return currentModel
		end,
		GetDomain = function(_self: Types.ActorView, domainId: string): Types.DomainView?
			local domain: Types.DomainViewOwner? = currentDomains[domainId]

			return if domain ~= nil then domain.view else nil
		end,
		GetDomainIds = function(_self: Types.ActorView): { string }
			return domainIds
		end,
		IsAvailable = function(_self: Types.ActorView): boolean
			return available
		end,
		OnModelChanged = Signal.wrapEvent(changed),
		OnDomainsChanged = Signal.wrapEvent(domainsChanged),
		OnUnavailable = Signal.wrapEvent(unavailable),
	})

	return {
		view = view,
		InstallModel = function(_self: Types.ActorViewOwner, nextModel: Model?): ()
			assert(not destroyed, "ActorViewDestroyed")
			currentModel = nextModel
		end,
		InstallDomains = function(
			_self: Types.ActorViewOwner,
			nextDomains: { [string]: Types.DomainViewOwner }
		): Types.DomainMembershipChange?
			assert(not destroyed, "ActorViewDestroyed")
			local added: { string } = {}
			local removed: { string } = {}

			for id: string in nextDomains do
				if currentDomains[id] == nil then
					table.insert(added, id)
				end
			end

			for id: string in currentDomains do
				if nextDomains[id] == nil then
					table.insert(removed, id)
				end
			end

			currentDomains = table.clone(nextDomains)
			updateDomainIds()

			if #added == 0 and #removed == 0 then
				return nil
			end

			table.sort(added)
			table.sort(removed)

			return table.freeze({ added = table.freeze(added), removed = table.freeze(removed) })
		end,
		InstallUnavailable = function(_self: Types.ActorViewOwner): ()
			available = false
		end,
		NotifyModelChanged = function(_self: Types.ActorViewOwner, previous: Model?, nextModel: Model?): ()
			if not destroyed then
				owned:WithDeferredDestroy(function()
					changed:Fire(previous, nextModel)
				end)
			end
		end,
		NotifyDomainsChanged = function(_self: Types.ActorViewOwner, change: Types.DomainMembershipChange): ()
			if not destroyed then
				owned:WithDeferredDestroy(function()
					domainsChanged:Fire(change)
				end)
			end
		end,
		NotifyUnavailable = function(_self: Types.ActorViewOwner): ()
			if not destroyed then
				owned:WithDeferredDestroy(function()
					unavailable:Fire()
				end)
			end
		end,
		Destroy = function(_self: Types.ActorViewOwner): ()
			if destroyed then
				return
			end

			destroyed = true
			tags:Destroy()
			resources:Destroy()
			actions:Destroy()
			available = false
			currentModel = nil

			for _, domain: Types.DomainViewOwner in currentDomains do
				domain:Destroy()
			end

			table.clear(currentDomains)
			domainIds = table.freeze({} :: { string })
			owned:Destroy()
		end,
	},
		nil
end

return ActorView
