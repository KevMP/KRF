local ResourceTypes = require(script.Parent.types)

type ResourceRegistry = ResourceTypes.ResourceRegistry
type ResourceDefinition = ResourceTypes.ResourceDefinition

local ResourceRegistry = {}
local isLoaded: boolean = false


function ResourceRegistry.Load(definitions: { ResourceDefinition }) : (boolean, string?)
  if isLoaded then 
    return false, "ResourceDefinitionsAlreadyLoaded"
  end
  
end

return ResourceRegistry :: ResourceRegistry 
