--!strict
local Types = require(script.Parent.Parent.types)
local Signal = require(script.Parent.Parent.Parent.Parent.shared.Signal.SignalModule)

-- N5 scaffold: this module owns future actorId/Model indexes and lifecycle
-- signals. Networking installs/removes views here; consumers only get the facade.
local owner: Types.ActorViewRegistryOwner = {
	GetActorViewById = function(_actorId: string): Types.ActorView?
		return nil
	end,
	GetActorViewByModel = function(_model: Model): Types.ActorView?
		return nil
	end,
	GetAllActorViews = function(): { Types.ActorView }
		return {}
	end,
	Install = function(_view: Types.ActorView): (boolean, string?)
		return false, "N5NotImplemented"
	end,
	InstallModel = function(_view: Types.ActorView, _previous: Model?, _current: Model?): (boolean, string?)
		return false, "N5NotImplemented"
	end,
	Remove = function(_view: Types.ActorView): () end,
	Reset = function(): () end,
	Added = Signal.new(),
	Removing = Signal.new(),
}

return owner
