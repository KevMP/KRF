--!strict
local Types = require(script.Parent.types)

-- Owns identity, Model, visible DomainView membership and Actor-level signals.
-- The returned private owner controls the immutable public view. Install methods
-- never notify; ActorViewRuntime coordinates publication across all owners.
local ActorView = {} :: Types.ActorViewModule

function ActorView.new(
	_actorId: string,
	_model: Model?,
	_domains: { [string]: Types.DomainViewOwner }
): (Types.ActorViewOwner?, string?)
	return nil, "N5NotImplemented"
end

return ActorView
