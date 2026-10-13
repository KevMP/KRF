--!strict
local PublicationTypes = require(script.Parent.PublicationTypes)
local ReplicationTypes = require(script.Parent.Parent.Replication.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)

local PublicationRuntime = {}
PublicationRuntime.__index = PublicationRuntime

function PublicationRuntime.new(
	_catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	_options: PublicationTypes.RuntimeOptions?
): PublicationTypes.Runtime
	return setmetatable({}, PublicationRuntime) :: any
end

function PublicationRuntime.ValidateEventBounds(
	_catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	_maxEventBytes: number
): (boolean, string?)
	error("N3NotImplemented", 2)
end

function PublicationRuntime.AttachActor(_self: PublicationTypes.Runtime, _actor: ActorTypes.Actor): (boolean, string?)
	error("N3NotImplemented", 2)
end

function PublicationRuntime.DetachActor(_self: PublicationTypes.Runtime, _actor: ActorTypes.Actor): ()
	error("N3NotImplemented", 2)
end

function PublicationRuntime.GetActorSequence(_self: PublicationTypes.Runtime, _actor: ActorTypes.Actor): number
	error("N3NotImplemented", 2)
end

function PublicationRuntime.GetAttachedActors(_self: PublicationTypes.Runtime): { ActorTypes.Actor }
	error("N3NotImplemented", 2)
end

function PublicationRuntime.CaptureBaseline(
	_self: PublicationTypes.Runtime,
	_actor: ActorTypes.Actor
): PublicationTypes.Baseline?
	error("N3NotImplemented", 2)
end

function PublicationRuntime.ObserveCommits(
	_self: PublicationTypes.Runtime,
	_observer: (commit: PublicationTypes.Commit) -> ()
): () -> ()
	error("N3NotImplemented", 2)
end

function PublicationRuntime.WithActorCommit(
	_self: PublicationTypes.Runtime,
	_actor: ActorTypes.Actor,
	_callback: () -> ()
): ()
	error("N3NotImplemented", 2)
end

function PublicationRuntime.Destroy(_self: PublicationTypes.Runtime): ()
	-- Empty instance: no resources exist yet.
end

return PublicationRuntime
