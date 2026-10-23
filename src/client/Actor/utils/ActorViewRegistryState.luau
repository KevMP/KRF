--!strict
local Types = require(script.Parent.Parent.types)
local Signal = require(script.Parent.Parent.Parent.Parent.shared.Signal.SignalModule)

local byId: { [string]: Types.ActorView } = {}
local byModel: { [Model]: Types.ActorView } = {}
local models: { [Types.ActorView]: Model } = {}
local identities: { [Types.ActorView]: boolean } = {}

local owner: Types.ActorViewRegistryOwner = {
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
		local model: Model? = view:GetModel()

		if byId[view:GetId()] ~= nil then
			return false, "ActorIdConflict"
		elseif model ~= nil and byModel[model] ~= nil then
			return false, "ActorModelConflict"
		end

		byId[view:GetId()] = view
		identities[view] = true

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
		table.clear(byId)
		table.clear(byModel)
		table.clear(models)
		table.clear(identities)
	end,
	Added = Signal.new(),
	Removing = Signal.new(),
}

return owner
