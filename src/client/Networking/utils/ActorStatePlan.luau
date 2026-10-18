--!strict
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Validator = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.SchemaValidator)
local Collections = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.SchemaCollectionUtils)

local ActorStatePlan = {}

-- Wrapper distinguishes successful Optional(nil) from failure.
export type Result = { read value: any }

export type Plan = {
	Snapshot: (any) -> (Result?, string?),
	Apply: (any, SharedNetworkingTypes.ActorPatch) -> (Result?, string?),
}

type Node = {
	Own: (value: any, previous: any) -> any,
	Apply: (previous: any, patch: SharedNetworkingTypes.ActorPatch) -> any,
}

local function requireValid(condition: boolean): ()
	assert(condition, "InvalidActorPatch")
end

local function compileNode(schema: SharedNetworkingTypes.CompiledSchema): Node
	local children: { [string]: Node } = {}
	local element: Node? = nil

	if schema.kind == "Struct" then
		for _, field: SharedNetworkingTypes.CompiledField in schema.fields do
			children[field.name] = compileNode(field.schema)
		end
	elseif schema.kind == "Array" then
		element = compileNode(schema.element)
	elseif schema.kind == "Map" then
		element = compileNode(schema.value)
	elseif schema.kind == "Optional" then
		element = compileNode(schema.inner)
	end

	local function own(value: any, previous: any): any
		if schema.kind == "Optional" then
			return if value == nil then nil else (element :: Node).Own(value, previous)
		elseif schema.kind ~= "Struct" and schema.kind ~= "Map" and schema.kind ~= "Array" then
			return value
		end

		local owned: { [any]: any } = {}
		local equal: boolean = type(previous) == "table"

		for key: any, item: any in next, value do
			local child: Node = if schema.kind == "Struct" then children[key] else element :: Node
			local prior: any = if type(previous) == "table" then rawget(previous, key) else nil

			owned[key] = child.Own(item, prior)

			if owned[key] ~= prior then
				equal = false
			end
		end

		if equal then
			for key: any in next, previous do
				if rawget(value, key) == nil then
					equal = false
					break
				end
			end
		end

		-- Only reuse containers already owned by Networking.
		return if equal and table.isfrozen(previous) then previous else table.freeze(owned)
	end

	local function apply(previous: any, patch: SharedNetworkingTypes.ActorPatch): any
		requireValid(type(patch) == "table")

		if patch.kind == "Replace" then
			requireValid(Validator.Validate(schema, patch.value))

			return own(patch.value, previous)
		elseif schema.kind == "Optional" then
			requireValid(previous ~= nil)

			return (element :: Node).Apply(previous, patch)
		end

		requireValid(type(previous) == "table")
		local result: { [any]: any }? = nil

		if patch.kind == "Struct" and schema.kind == "Struct" then
			requireValid(type(patch.fields) == "table")

			for name: string, fieldPatch: SharedNetworkingTypes.ActorPatch in next, patch.fields do
				local child: Node? = children[name]
				requireValid(child ~= nil)
				local value: any = (child :: Node).Apply(rawget(previous, name), fieldPatch)

				if value ~= rawget(previous, name) then
					local changed: { [any]: any } = result or table.clone(previous)
					changed[name] = value
					result = changed
				end
			end
		elseif patch.kind == "Map" and schema.kind == "Map" then
			requireValid(type(patch.entries) == "table" and type(patch.removed) == "table")
			requireValid(Collections.GetArrayLength(patch.removed) ~= nil)
			local removed: { [any]: boolean } = {}

			for _, key: any in patch.removed do
				requireValid(Validator.Validate(schema.key, key))
				requireValid(not removed[key] and rawget(patch.entries, key) == nil)
				removed[key] = true

				if rawget(previous, key) ~= nil then
					local changed: { [any]: any } = result or table.clone(previous)
					changed[key] = nil
					result = changed
				end
			end

			for key: any, item: any in next, patch.entries do
				requireValid(Validator.Validate(schema.key, key))
				requireValid(Validator.Validate(schema.value, item))
				local value: any = (element :: Node).Own(item, rawget(previous, key))

				if value ~= rawget(previous, key) then
					local changed: { [any]: any } = result or table.clone(previous)
					changed[key] = value
					result = changed
				end
			end

			if result ~= nil then
				local count: number = 0

				for _ in next, result do
					count += 1
				end

				requireValid(count <= schema.maxEntries)
			end
		else
			error("InvalidActorPatch", 0)
		end

		return if result == nil then previous else table.freeze(result)
	end

	return { Own = own, Apply = apply }
end

function ActorStatePlan.Compile(schema: SharedNetworkingTypes.CompiledSchema): Plan
	local node: Node = compileNode(schema)

	return {
		Snapshot = function(value: any): (Result?, string?)
			if not Validator.Validate(schema, value) then
				return nil, "InvalidActorState"
			end

			return table.freeze({ value = node.Own(value, nil) }), nil
		end,
		Apply = function(previous: any, patch: SharedNetworkingTypes.ActorPatch): (Result?, string?)
			local success: boolean, value: any = pcall(node.Apply, previous, patch)

			if not success then
				return nil, "InvalidActorPatch"
			end

			return table.freeze({ value = value }), nil
		end,
	}
end

return ActorStatePlan
