--!strict
local Types = require(script.Parent.types)
local Signal = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)
local Owner: Types.ActorViewRegistryOwner = require(script.Parent.utils.ActorViewRegistryState)

-- The immutable public facade delegates to a separate framework-private owner.
-- Freezing this API does not freeze its private indexes or installation lifecycle.
local registry: Types.ActorViewRegistry = {
	GetActorViewById = Owner.GetActorViewById,
	GetActorViewByModel = Owner.GetActorViewByModel,
	GetAllActorViews = Owner.GetAllActorViews,
	OnActorViewAdded = Signal.wrapEvent(Owner.Added),
	OnActorViewRemoving = Signal.wrapEvent(Owner.Removing),
}

return table.freeze(registry)
