--!strict
--[[
Actor Contract
- Stable actor.id (internal correlation id)
- actor.model may be nil
- actor.enabled defaults to false
- Controllers: Set/Get/Remove with no overwrite
- Stored controllers must support Destroy() for consistent teardown
]]
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)

local ActorTypes = {}

export type ActorBase = {
	model: Model?,
	enabled: boolean,
}

export type Controller = {
	Destroy: (self: Controller) -> (),
}

export type ActorApi = {
	GetId: (self: ActorApi) -> string,

	SetController: (self: ActorApi, key: string, controller: Controller) -> boolean,
	GetControllerKeys: (self: ActorApi) -> { string },
	GetController: (self: ActorApi, key: string) -> Controller?,
	RemoveController: (self: Actor, key: string) -> Controller?,
}

export type Actor = ActorBase & ActorApi

export type ActorRegistry = {
	GetActorById: (actorId: string) -> Actor?,
	GetActorByModel: (actorModel: Model) -> Actor?,
	BindModel: (actor: Actor, model: Model) -> (boolean, string?),
	UnbindModel: (actor: Actor) -> boolean,
	-- Installed by ActorRuntime to avoid require cycles.
	-- Pass nil to clear (optional but nice for tests).
	SetModelGoneHandler: (handler: ((actor: Actor, reason: string) -> ())?) -> (),
}

export type RegisterActorOpts = {
	ownerUserId: number?, -- reserved for future Networking/Input ownership semantics
}

export type ActorRuntime = {
	RegisterActor: (model: Model, opts: RegisterActorOpts?) -> (Actor?, string?),
	UnregisterActor: (actor: Actor, reason: string?) -> (boolean, string?),
	AttachControllers: (actor: Actor) -> (boolean, string?),
	DetachAllControllers: (actor: Actor) -> (),

	--events
	OnActorRegistered: SignalTypes.Event<Actor>,
	OnActorUnregistering: SignalTypes.Event<Actor, string?>,
	OnActorUnregistered: SignalTypes.Event<Actor, string?>,
}

return ActorTypes
