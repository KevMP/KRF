--!strict
local ActorTypes = require(script.Parent.Parent.types)
local PropertyRegistry = require(script.Parent.Parent.Parent.Property.PropertyRegistry)

local ActorRegistrationOptions = {}

function ActorRegistrationOptions.Prepare(options: ActorTypes.RegisterActorOpts?): ({ [string]: number }?, string?)
	if options == nil then
		return {}, nil
	end

	if type(options) ~= "table" then
		return nil, "InvalidActorRegistrationOptions"
	end

	local optionsTable = options :: { [string]: unknown }

	for key in next, optionsTable do
		if key ~= "properties" then
			return nil, "InvalidActorRegistrationOptions"
		end
	end

	local properties: any = rawget(optionsTable, "properties")
	local owned: { [string]: number } = {}

	if properties == nil then
		return owned, nil
	end

	if type(properties) ~= "table" then
		return nil, "InvalidActorProperties"
	end

	for id, value in next, properties do
		if type(id) ~= "string" or id == "" then
			return nil, "InvalidPropertyId"
		end

		if PropertyRegistry.Get(id) == nil then
			return nil, "UnknownPropertyId"
		end

		if type(value) ~= "number" or not math.isfinite(value) then
			return nil, "InvalidInitialPropertyValue"
		end

		owned[id] = value
	end

	return owned, nil
end

return ActorRegistrationOptions
