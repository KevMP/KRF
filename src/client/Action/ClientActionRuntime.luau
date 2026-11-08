--!strict
local Types = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local SharedRequestTypes = require(script.Parent.Parent.Parent.shared.ActionRequest.types)
local State = require(script.Parent.utils.ClientActionRuntimeState)

local emptySources: { Types.ProfileSourceSnapshot } = table.freeze({} :: { Types.ProfileSourceSnapshot })

local facade: Types.ClientActionRuntime = {
	RetireRequest = function(original: number): (boolean, string?)
		local owner: Types.ActionInputOwner? = State.GetInput()

		if owner == nil then
			return false, "ClientNotReady"
		end

		return owner.RetireRequest(original)
	end,
	RequestAction = function(actor: ActorTypes.ActorView, actionId: string, parameters: any?): (number?, string?)
		local owner: Types.ActionInputOwner? = State.GetInput()

		if owner == nil then
			return nil, "ClientNotReady"
		end

		return owner.RequestAction(actor, actionId, parameters)
	end,
	RequestStop = function(original: number, parameters: any?): (number?, string?)
		local owner: Types.ActionInputOwner? = State.GetInput()

		if owner == nil then
			return nil, "ClientNotReady"
		end

		return owner.RequestStop(original, parameters)
	end,
	RequestInterrupt = function(
		original: number,
		reason: SharedRequestTypes.ActionInputInterruptReason
	): (number?, string?)
		local owner: Types.ActionInputOwner? = State.GetInput()

		if owner == nil then
			return nil, "ClientNotReady"
		end

		return owner.RequestInterrupt(original, reason)
	end,
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

		return if owner == nil then emptySources else owner.GetProfileSources(actor)
	end,
}

return table.freeze(facade)
