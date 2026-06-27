local ResourceTypes = require(script.Parent.Parent.types)
type ResourceDefinition = ResourceTypes.ResourceDefinition

local ResourceDefinitionValidator = {}

function ResourceDefinitionValidator.ValidateResourceDefinition(definition: ResourceDefinition): (boolean, string?) end

return ResourceDefinitionValidator
