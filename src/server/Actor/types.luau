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
	-- `self` is intentionally loose here to keep public controller hovers concise.
	Destroy: (any) -> (),
}

export type ActorApi = {
	-- Public `self` is intentionally loose to keep actor method hovers readable.
	GetId: (any) -> string,

	SetController: (any, key: string, controller: Controller) -> boolean,
	GetControllerKeys: (any) -> { string },
	GetController: (any, key: string) -> Controller?,
	RemoveController: (any, key: string) -> Controller?,
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
