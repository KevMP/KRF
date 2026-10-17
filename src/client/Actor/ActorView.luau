--!strict
local Types = require(script.Parent.types)
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
	local changed: SignalTypes.Signal<Model?, Model?> = Signal.new()
	local owned: SignalTypes.OwnedSignals = OwnedSignals.new({ changed })
	local function updateDomainIds(): ()
		domainIds = {}
		for id: string in currentDomains do
			table.insert(domainIds, id)
		end
		table.sort(domainIds)
		table.freeze(domainIds)
	end
	updateDomainIds()
	local view: Types.ActorView = table.freeze({
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
		OnModelChanged = Signal.wrapEvent(changed),
	})
	return {
		view = view,
		InstallModel = function(_self: Types.ActorViewOwner, nextModel: Model?): ()
			assert(not destroyed, "ActorViewDestroyed")
			currentModel = nextModel
		end,
		InstallDomains = function(_self: Types.ActorViewOwner, nextDomains: { [string]: Types.DomainViewOwner }): ()
			assert(not destroyed, "ActorViewDestroyed")
			currentDomains = table.clone(nextDomains)
			updateDomainIds()
		end,
		NotifyModelChanged = function(_self: Types.ActorViewOwner, previous: Model?, nextModel: Model?): ()
			if not destroyed then
				owned:WithDeferredDestroy(function()
					changed:Fire(previous, nextModel)
				end)
			end
		end,
		Destroy = function(_self: Types.ActorViewOwner): ()
			if destroyed then
				return
			end
			destroyed = true
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
