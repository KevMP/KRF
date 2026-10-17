--!strict
local Types = require(script.Parent.types)
local Signal = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)

-- N5 TDD scaffold: event surfaces are loadable; publication/indexing is not implemented.
local added: Signal.Signal<Types.ActorView> = Signal.new()
local removing: Signal.Signal<Types.ActorView> = Signal.new()
local registry: Types.ActorViewRegistry = {
	GetActorViewById = function(_actorId: string): Types.ActorView?
		return nil
	end,
	GetActorViewByModel = function(_model: Model): Types.ActorView?
		return nil
	end,
	GetAllActorViews = function(): { Types.ActorView }
		return {}
	end,
	OnActorViewAdded = Signal.wrapEvent(added),
	OnActorViewRemoving = Signal.wrapEvent(removing),
}

return registry
