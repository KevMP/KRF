--!strict
local Types = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local State = require(script.Parent.utils.ClientActionRuntimeState)

local facade: Types.ClientActionRuntime = {
	SetProfileSource = function(
		actor: ActorTypes.ActorView,
		sourceId: string,
		profile: Types.ControlProfile
	): (boolean, string?)
		local owner: Types.ClientActionOwner? = State.Get()

		if owner == nil then
			return false, "ClientNotReady"
		end

		return owner.SetProfileSource(actor, sourceId, profile)
	end,
	RemoveProfileSource = function(actor: ActorTypes.ActorView, sourceId: string): (boolean, string?)
		local owner: Types.ClientActionOwner? = State.Get()

		if owner == nil then
			return false, "ClientNotReady"
		end

		return owner.RemoveProfileSource(actor, sourceId)
	end,
	SetControlledActor = function(actor: ActorTypes.ActorView?): (boolean, string?)
		local owner: Types.ClientActionOwner? = State.Get()

		if owner == nil then
			return false, "ClientNotReady"
		end

		return owner.SetControlledActor(actor)
	end,
	GetControlledActor = function(): ActorTypes.ActorView?
		local owner: Types.ClientActionOwner? = State.Get()

		return if owner == nil then nil else owner.GetControlledActor()
	end,
	GetEffectiveRoute = function(actor: ActorTypes.ActorView, key: Types.RouteKey): Types.RouteQuerySnapshot?
		local owner: Types.ClientActionOwner? = State.Get()

		return if owner == nil then nil else owner.GetEffectiveRoute(actor, key)
	end,
	GetProfileSources = function(actor: ActorTypes.ActorView): { Types.ProfileSourceSnapshot }
		local owner: Types.ClientActionOwner? = State.Get()

		return if owner == nil then {} else owner.GetProfileSources(actor)
	end,
}

return table.freeze(facade)
