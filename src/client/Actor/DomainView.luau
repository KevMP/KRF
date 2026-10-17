--!strict
local Types = require(script.Parent.types)

-- Owns current immutable state, OnChanged, declared events and owned-signal
-- teardown. Schema validation/patching belongs to ActorStatePlan. State install
-- and notification are separate so Networking can publish a whole Actor atomically.
local DomainView = {} :: Types.DomainViewModule

function DomainView.new(
	_domainId: string,
	_immutableState: any,
	_eventIds: { string }
): (Types.DomainViewOwner?, string?)
	return nil, "N5NotImplemented"
end

return DomainView
