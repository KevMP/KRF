--!strict
local Types = require(script.Parent.Parent.types)
local Composition = {}

-- Owned truth patching and coalescing are pure value operations. The scheduler
-- alone owns barriers, queue order, admission charges and delivered indexes.
function Composition.Copy(value: any): any
	if type(value) ~= "table" then
		return value
	end

	local result: { [any]: any } = {}

	for key, item in value do
		result[key] = Composition.Copy(item)
	end

	return result
end

local function apply(value: any, patch: Types.PublicationPatch): any
	if patch.kind == "Replace" then
		return Composition.Copy(patch.value)
	end

	-- Delivered subtrees are private. Copy only the path changed by this patch;
	-- incoming replacement values and Map entries still cross an ownership boundary.
	local result = if type(value) == "table" then table.clone(value) else {}

	if patch.kind == "Struct" then
		for field, change in patch.fields do
			result[field] = apply(result[field], change)
		end
	else
		for key, entry in patch.entries do
			result[key] = Composition.Copy(entry)
		end

		for _, key in patch.removed do
			result[key] = nil
		end
	end

	return result
end

local function merge(
	first: Types.PublicationPatch,
	second: Types.PublicationPatch,
	delivered: Types.PublicationDomainTruth?
): Types.PublicationPatch?
	if second.kind == "Replace" or first.kind ~= second.kind then
		return second
	end

	if first.kind == "Struct" and second.kind == "Struct" then
		local fields: { [string]: Types.PublicationPatch } = table.clone(first.fields)

		for field, change in second.fields do
			local earlier = fields[field]
			local fieldTruth: Types.PublicationDomainTruth? = nil

			if delivered ~= nil and type(delivered.value) == "table" then
				fieldTruth = { value = delivered.value[field] }
			end

			fields[field] = if earlier == nil then change else merge(earlier, change, fieldTruth)
		end

		return { kind = "Struct", fields = fields }
	end

	if first.kind == "Map" and second.kind == "Map" then
		local entries: { [any]: any } = table.clone(first.entries)
		local removals: { [any]: boolean } = {}

		for _, key in first.removed do
			removals[key] = true
		end

		for key, value in second.entries do
			entries[key] = value
			removals[key] = nil
		end

		for _, key in second.removed do
			entries[key] = nil

			if delivered ~= nil and type(delivered.value) == "table" and delivered.value[key] == nil then
				removals[key] = nil
			else
				removals[key] = true
			end
		end

		local removed: { any } = {}

		for key in removals do
			table.insert(removed, key)
		end

		table.sort(removed, function(a: any, b: any): boolean
			return a < b
		end)

		if next(entries) == nil and #removed == 0 then
			return nil
		end

		return { kind = "Map", entries = entries, removed = removed }
	end

	return second
end

function Composition.Combine(
	first: Types.PublicationFilteredCommit?,
	second: Types.PublicationFilteredCommit,
	delivered: { [string]: Types.PublicationDomainTruth }
): Types.PublicationFilteredCommit
	if first == nil then
		return second
	end

	local byDomain: { [string]: Types.PublicationPatch } = {}
	local order: { string } = {}

	for _, item in first.patches do
		byDomain[item.domainId] = item.patch
		table.insert(order, item.domainId)
	end

	for _, item in second.patches do
		local previous = byDomain[item.domainId]

		if previous == nil then
			byDomain[item.domainId] = item.patch
			table.insert(order, item.domainId)
		else
			byDomain[item.domainId] = merge(previous, item.patch, delivered[item.domainId])
		end
	end

	local patches: { Types.PublicationDomainPatch } = {}

	for _, domainId in order do
		local patch = byDomain[domainId]

		if patch ~= nil then
			table.insert(patches, { domainId = domainId, patch = patch })
		end
	end

	local events: { Types.PublicationEvent } = {}

	for _, event in first.events do
		table.insert(events, event)
	end

	for _, event in second.events do
		table.insert(events, event)
	end

	return { sequence = second.sequence, patches = patches, events = events }
end

function Composition.ApplyKnown(
	truth: { [string]: Types.PublicationDomainTruth },
	domainId: string,
	patch: Types.PublicationPatch
): ()
	local previous = truth[domainId]

	if previous ~= nil then
		truth[domainId] = { value = apply(previous.value, patch) }
	elseif patch.kind == "Replace" then
		truth[domainId] = { value = Composition.Copy(patch.value) }
	end
end

return Composition
