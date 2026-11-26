--!strict
local Types = require(script.Parent.Parent.types)
local Sources = require(script.Parent.PresentationSources)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)

export type Scope = {
	read descriptor: Types.PresentationEventDescriptor,
	read id: string?,
	read actor: ActorTypes.ActorView?,
	read anyHint: boolean,
	read activation: boolean,
}

local Scope = {}

function Scope.Resolve(
	definitionId: string,
	entry: Types.PresentationEntryEvent,
	association: Types.PresentationActionAssociation?,
	isEligible: (ActorTypes.ActorView) -> boolean,
	descriptor: any,
	...: any
): (Scope, (Types.PresentationEntryEvent) -> ())
	local function misuse(reason: string): never
		error(("[Presentation] id=%s On: %s"):format(definitionId, reason), 4)
	end

	if not Sources.IsKnown(descriptor) then
		misuse("UnknownEventDescriptor: use PresentationEvents constants")
	end

	local arity: number = select("#", ...)

	if arity ~= 1 and arity ~= 2 then
		misuse("InvalidArguments: expected event, [id or scope,] callback")
	end

	local filter: any, last: any = ...
	local callback: any = if arity == 1 then filter else last

	if type(callback) ~= "function" then
		misuse("CallbackInvalid: expected a function")
	end

	local id: string? = nil
	local actor: ActorTypes.ActorView? = entry.actor
	local anyHint: boolean = false
	local activation: boolean = false

	if arity == 1 then
		if descriptor.source == "Action" then
			if association == nil then
				misuse("OriginActionMissing: supply an explicit id")
			end

			activation = true
			actor = assert(association).actor
		elseif descriptor.source ~= entry.source then
			misuse("OriginIdMissing: supply an explicit id for this source family")
		elseif entry.source == "Tag" then
			id = entry.tagId
		elseif entry.source == "Resource" then
			id = entry.change.resourceId
		elseif entry.source == "Hint" then
			id = entry.hintId
		end
	elseif type(filter) == "string" then
		id = filter
	elseif type(filter) == "table" and getmetatable(filter) == nil then
		for field: any in next, filter do
			if field ~= "id" and field ~= "actor" and field ~= "scope" then
				misuse("ScopeFieldUnknown: use id and actor, or Hint id and scope=Any")
			end
		end

		if filter.actor ~= nil and filter.scope == nil then
			actor = filter.actor
		elseif descriptor.source == "Hint" and filter.scope == "Any" and filter.actor == nil then
			anyHint = true
			actor = nil
		else
			misuse("ScopeInvalid: provide an ActorView or explicit Hint scope=Any")
		end

		id = filter.id
	else
		misuse("FilterInvalid: expected a nonempty id or scope record")
	end

	if not activation and (type(id) ~= "string" or id == "") then
		misuse("IdInvalid: expected a nonempty source id")
	end

	if actor == nil and descriptor.source ~= "Hint" then
		misuse("ActorMissing: provide an explicit ActorView scope and id")
	elseif actor ~= nil and not isEligible(actor) then
		misuse("ActorUnavailable: scope must be a current available ActorView")
	end

	return { descriptor = descriptor, id = id, actor = actor, anyHint = anyHint, activation = activation }, callback
end

return table.freeze(Scope)
