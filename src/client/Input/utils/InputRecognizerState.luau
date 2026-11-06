--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.InputConstants)
local Value = require(script.Parent.InputValue)
local Validation = require(script.Parent.InputRecognitionValidation)
export type Store = { values: { [string]: Types.RecognitionScalar }, slots: number, bytes: number }

local State = {}

local function keyValid(key: any): boolean
	return type(key) == "string" and #key > 0 and #key <= Constants.MAX_RECOGNIZER_KEY_BYTES
end

local function scalar(value: any): boolean
	return type(value) == "boolean" or type(value) == "string" or Value.IsFinite(value)
end

local function size(key: string, value: Types.RecognitionScalar): number
	return #key + (if type(value) == "string" then #value else if type(value) == "boolean" then 1 else 8)
end

function State.new(): Store
	return { values = {}, slots = 0, bytes = 0 }
end

function State.Get(store: Store, key: any): (Types.RecognitionScalar?, string?)
	if not keyValid(key) then
		return nil, "InvalidRecognizerState"
	end

	return store.values[key], nil
end

function State.Set(store: Store, key: any, value: any): (boolean, string?)
	if not keyValid(key) or (value ~= nil and not scalar(value)) then
		return false, "InvalidRecognizerState"
	end

	local previous: Types.RecognitionScalar? = store.values[key]
	local slots: number = store.slots - (if previous ~= nil then 1 else 0) + (if value ~= nil then 1 else 0)

	local bytes: number = store.bytes
		- (if previous ~= nil then size(key, previous) else 0)
		+ (if value ~= nil then size(key, value) else 0)

	if slots > Constants.MAX_RECOGNIZER_STATE_SLOTS or bytes > Constants.MAX_RECOGNIZER_STATE_BYTES then
		return false, "RecognizerStateLimitExceeded"
	end

	store.values[key] = value
	store.slots = slots
	store.bytes = bytes

	return true, nil
end

function State.Match(raw: any): (Types.CustomMatch?, string?)
	if raw == nil then
		return nil, nil
	end

	if not Validation.Fields(raw, { metadata = true }) then
		return nil, "InvalidRecognizerResult"
	end

	local metadata: { [string]: Types.RecognitionScalar }? = nil

	if raw.metadata ~= nil then
		if not Validation.Plain(raw.metadata) then
			return nil, "InvalidRecognizerResult"
		end

		metadata = {}
		local bytes: number = 0
		local slots: number = 0

		for key: any, value: any in raw.metadata do
			if not keyValid(key) or not scalar(value) then
				return nil, "InvalidRecognizerResult"
			end

			slots += 1
			bytes += size(key, value)

			if slots > Constants.MAX_RECOGNIZER_METADATA_SLOTS or bytes > Constants.MAX_RECOGNIZER_METADATA_BYTES then
				return nil, "InvalidRecognizerResult"
			end

			metadata[key] = value
		end

		table.freeze(metadata)
	end

	local result: Types.CustomMatch = { metadata = metadata }

	return table.freeze(result) :: Types.CustomMatch, nil
end

return State
