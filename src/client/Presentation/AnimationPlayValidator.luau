--!strict
local Types = require(script.Parent.types)
local ContentId = require(script.Parent.utils.ContentId)

local OPTION_FIELDS: { [string]: boolean } = {
	fadeTime = true,
	weight = true,
	speed = true,
	priority = true,
	looped = true,
}

table.freeze(OPTION_FIELDS)

local DEFAULTS: Types.CompiledAnimationPlayOptions = table.freeze({
	fadeTime = 0.1,
	weight = 1,
	speed = 1,
	priority = Enum.AnimationPriority.Action,
	looped = false,
})

local Validator = {}

local function finite(value: unknown): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Validator.IsFadeTime(value: unknown): boolean
	return finite(value) and (value :: number) >= 0
end

function Validator.IsWeight(value: unknown): boolean
	return finite(value) and (value :: number) >= 0
end

function Validator.IsSpeed(value: unknown): boolean
	return finite(value)
end

function Validator.AnimationId(value: unknown): (string?, string?)
	local normalized: string? = ContentId.Normalize(value)

	if normalized == nil then
		return nil, "AnimationIdInvalid"
	end

	return normalized, nil
end

function Validator.Options(value: unknown): (Types.CompiledAnimationPlayOptions?, string?)
	if value == nil then
		return DEFAULTS, nil
	elseif type(value) ~= "table" or getmetatable(value :: any) ~= nil then
		return nil, "AnimationOptionsInvalid"
	end

	local options: { [unknown]: unknown } = value :: any

	for name: unknown in next, options do
		if type(name) ~= "string" or not OPTION_FIELDS[name] then
			return nil, "AnimationOptionUnknown"
		end
	end

	local fadeTime: unknown = options.fadeTime
	local weight: unknown = options.weight
	local speed: unknown = options.speed
	local priority: unknown = options.priority
	local looped: unknown = options.looped

	if fadeTime ~= nil and not Validator.IsFadeTime(fadeTime) then
		return nil, "AnimationFadeTimeInvalid"
	elseif weight ~= nil and not Validator.IsWeight(weight) then
		return nil, "AnimationWeightInvalid"
	elseif speed ~= nil and not Validator.IsSpeed(speed) then
		return nil, "AnimationSpeedInvalid"
	elseif
		priority ~= nil
		and (typeof(priority) ~= "EnumItem" or (priority :: EnumItem).EnumType ~= Enum.AnimationPriority)
	then
		return nil, "AnimationPriorityInvalid"
	elseif looped ~= nil and type(looped) ~= "boolean" then
		return nil, "AnimationLoopedInvalid"
	end

	return table.freeze({
		fadeTime = if fadeTime ~= nil then fadeTime :: number else DEFAULTS.fadeTime,
		weight = if weight ~= nil then weight :: number else DEFAULTS.weight,
		speed = if speed ~= nil then speed :: number else DEFAULTS.speed,
		priority = if priority ~= nil then priority :: Enum.AnimationPriority else DEFAULTS.priority,
		looped = if looped ~= nil then looped :: boolean else DEFAULTS.looped,
	}),
		nil
end

return table.freeze(Validator)
