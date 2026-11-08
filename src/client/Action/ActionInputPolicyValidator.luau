--!strict
local Types = require(script.Parent.types)
local RequestTypes = require(script.Parent.Parent.Parent.shared.ActionRequest.types)
local Payload = require(script.Parent.Parent.Parent.shared.ActionRequest.utils.ActionPayloadCodec)

local MAX_POLICIES: number = 4096

local FIELDS: { [string]: boolean } =
	{ activation = true, onInvalidation = true, startParameters = true, stopParameters = true }

table.freeze(FIELDS)
local Validator = {}

local function compile(
	value: any,
	wire: RequestTypes.CompiledActionRequest
): (Types.CompiledActionInputPolicy?, string?)
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return nil, "ActionInputPolicyInvalid"
	end

	for key: any in next, value do
		if not FIELDS[key] then
			return nil, "ActionInputPolicyFieldUnknown"
		end
	end

	local activation: any = if rawget(value, "activation") == nil then "OneShot" else rawget(value, "activation")
	local invalidation: any = rawget(value, "onInvalidation")

	if activation ~= "OneShot" and activation ~= "WhileDown" and activation ~= "Toggle" then
		return nil, "ActionInputActivationInvalid"
	elseif invalidation ~= nil and invalidation ~= "Keep" and invalidation ~= "Interrupt" then
		return nil, "ActionInputInvalidationInvalid"
	end

	for _, key: string in { "startParameters", "stopParameters" } do
		if rawget(value, key) ~= nil and type(rawget(value, key)) ~= "function" then
			return nil, "ActionInputProducerInvalid"
		end
	end

	if wire.requiresClientRelease and (rawget(value, "activation") ~= "WhileDown") then
		return nil, "ActionInputReleasePolicyRequired"
	end

	local automatic: boolean = activation ~= "OneShot"

	if automatic then
		if wire.stop == nil then
			return nil, "ActionInputStopRequired"
		elseif value.stopParameters == nil and Payload.Encode(wire.stop, nil) == nil then
			return nil, "ActionInputStopProducerRequired"
		end
	end

	invalidation = invalidation or (if activation == "WhileDown" then "Interrupt" else "Keep")

	if (invalidation == "Interrupt" or value.stopParameters ~= nil) and not wire.allowInputInterrupt then
		return nil, "ActionInputInterruptRequired"
	end

	return table.freeze({
		activation = activation,
		onInvalidation = invalidation,
		startParameters = value.startParameters,
		stopParameters = value.stopParameters,
	}),
		nil
end

function Validator.Compile(value: any, wire: RequestTypes.ActionRequestCatalog?): (Types.ActionInputCatalog?, string?)
	if value ~= nil and (type(value) ~= "table" or getmetatable(value) ~= nil) then
		return nil, "ActionInputPoliciesInvalid"
	end

	local policies: any = value or {}
	local count: number = 0

	for _: any in next, policies do
		count += 1

		if count > MAX_POLICIES then
			return nil, "ActionInputPolicyLimitExceeded"
		end
	end

	for actionId: any in next, policies do
		if type(actionId) ~= "string" or wire == nil or wire.requestsById[actionId] == nil then
			return nil, "ActionInputPolicyUnknownAction"
		end
	end

	local result: { [string]: Types.CompiledActionInputPolicy } = {}

	for index: number, actionId: string in if wire ~= nil then wire.actionIds else {} do
		if index > MAX_POLICIES then
			return nil, "ActionInputPolicyLimitExceeded"
		end

		local request: RequestTypes.CompiledActionRequest =
			assert(wire, "Expected request catalog").requestsById[actionId]

		local raw: any = rawget(policies, actionId)

		local policy: Types.CompiledActionInputPolicy?, reason: string? =
			compile(if raw == nil then {} else raw, request)

		if policy == nil then
			return nil, reason
		end

		result[actionId] = policy
	end

	return table.freeze(result), nil
end

return Validator
