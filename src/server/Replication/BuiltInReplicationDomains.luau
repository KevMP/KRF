--!strict
local ReplicationTypes = require(script.Parent.types)

-- N6-N8 add framework projections here. They share the game's domain namespace
-- and pass through the same startup validation and publication transaction.
local definitions: { ReplicationTypes.ReplicationDomainDefinition } = {}

return table.freeze(definitions)
