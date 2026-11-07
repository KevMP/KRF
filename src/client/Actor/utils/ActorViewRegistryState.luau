--!strict
local Types = require(script.Parent.Parent.types)
local Signal = require(script.Parent.Parent.Parent.Parent.shared.Signal.SignalModule)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)

local byId: { [string]: Types.ActorView } = {}
local byModel: { [Model]: Types.ActorView } = {}
local models: { [Types.ActorView]: Model } = {}
local identities: { [Types.ActorView]: boolean } = {}
local retired: { [Types.ActorView]: boolean } = setmetatable({}, { __mode = "k" })

local invalidations: Observers.Registry<(Types.ActorView, string) -> ()> =
	Observers.new(64, "ActorInvalidationObserverLimitExceeded") :: Observers.Registry<(Types.ActorView, string) -> ()>

local resetting: boolean = false
local invalidationDepth: number = 0

local function invalidate(view: Types.ActorView, reason: string): ()
	if identities[view] ~= true or retired[view] then
		return
	end

	retired[view] = true
	invalidationDepth += 1

	for _, entry in invalidations.Snapshot() do
		if entry.active then
			Observers.Run(entry.callback, view, reason)
		end
	end

	invalidationDepth -= 1
end

local owner: Types.ActorViewRegistryOwner = {
	IsInvalidationInProgress = function(): boolean
		return invalidationDepth > 0
	end,
	Invalidate = invalidate,
	IsInvalidating = function(view: Types.ActorView): boolean
		return retired[view] == true
	end,
	ObserveInvalidation = invalidations.Add,
	IsCurrent = function(view: Types.ActorView): boolean
		return identities[view] == true
	end,
	GetActorViewById = function(actorId: string): Types.ActorView?
		return byId[actorId]
	end,
	GetActorViewByModel = function(model: Model): Types.ActorView?
		return byModel[model]
	end,
	GetAllActorViews = function(): { Types.ActorView }
		local views: { Types.ActorView } = {}

		for _, view: Types.ActorView in byId do
			table.insert(views, view)
		end

		return views
	end,
	Install = function(view: Types.ActorView): (boolean, string?)
		if resetting then
			return false, "RegistryResetInProgress"
		end

		local model: Model? = view:GetModel()

		if byId[view:GetId()] ~= nil then
			return false, "ActorIdConflict"
		elseif model ~= nil and byModel[model] ~= nil then
			return false, "ActorModelConflict"
		end

		byId[view:GetId()] = view
		identities[view] = true
		retired[view] = nil

		if model ~= nil then
			byModel[model] = view
			models[view] = model
		end

		return true, nil
	end,
	InstallModel = function(view: Types.ActorView, _previous: Model?, current: Model?): (boolean, string?)
		if byId[view:GetId()] ~= view then
			return false, "ActorViewUnavailable"
		elseif current ~= nil and byModel[current] ~= nil and byModel[current] ~= view then
			return false, "ActorModelConflict"
		end

		local indexed: Model? = models[view]

		if indexed ~= nil then
			byModel[indexed] = nil
		end

		models[view] = current

		if current ~= nil then
			byModel[current] = view
		end

		return true, nil
	end,
	Remove = function(view: Types.ActorView): ()
		invalidate(view, "ActorRemoved")
		identities[view] = nil

		if byId[view:GetId()] == view then
			byId[view:GetId()] = nil
		end

		local model: Model? = models[view]

		if model ~= nil and byModel[model] == view then
			byModel[model] = nil
		end

		models[view] = nil
	end,
	Reset = function(): ()
		if resetting then
			return
		end

		resetting = true

		for view: Types.ActorView in table.clone(identities) do
			invalidate(view, "RegistryReset")
		end

		table.clear(byId)
		table.clear(byModel)
		table.clear(models)
		table.clear(identities)
		resetting = false
	end,
	Added = Signal.new(),
	Removing = Signal.new(),
}

return owner
