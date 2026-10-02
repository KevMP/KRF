--!strict
local ActionTypes = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local SignalModule = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)

type Actor = ActorTypes.Actor
type ActionController = ActionTypes.ActionController

local ActionControllerModule = {}

function ActionControllerModule.new(_actor: Actor): ActionController
	local grantChangedSignal: SignalTypes.Signal<Actor, string, boolean> = SignalModule.new()
	local controller: ActionController = {
		OnActionGrantChanged = SignalModule.wrapEvent(grantChangedSignal),
		Destroy = function(_self: ActionController): ()
			grantChangedSignal:Destroy()
		end,
		SetGrants = function(_self: ActionController, _sourceId: string, _actionIds: { string }): (boolean, string?)
			return false, "NotImplemented"
		end,
		IsActionGranted = function(_self: ActionController, _actionId: string): boolean
			return false
		end,
		GetGrantedActions = function(_self: ActionController): { string }
			return {}
		end,
	}
	return controller
end

return ActionControllerModule
