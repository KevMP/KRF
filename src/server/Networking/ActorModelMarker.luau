--!strict
local Types = require(script.Parent.AwarenessTypes)
local ActorTypes = require(script.Parent.Parent.Actor.types)

local ActorModelMarker = {} :: Types.MarkerModule

function ActorModelMarker.Install(_actor: ActorTypes.Actor): (boolean, string?)
	error("N4NotImplemented:ActorModelMarker.Install")
end

function ActorModelMarker.Remove(_actor: ActorTypes.Actor): ()
	error("N4NotImplemented:ActorModelMarker.Remove")
end

function ActorModelMarker.GetActorId(_marker: Instance): string?
	error("N4NotImplemented:ActorModelMarker.GetActorId")
end

function ActorModelMarker.GetMarker(_model: Model): Instance?
	error("N4NotImplemented:ActorModelMarker.GetMarker")
end

return ActorModelMarker
