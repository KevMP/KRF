--!strict
local Types = require(script.Parent.Parent.types)
local States = require(script.Parent.Parent.PresentationStates)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)

export type StateFamily = "Tag" | "Action" | "Resource" | "Actor"
export type Signature = { number | boolean | Instance }

type TagState = { read stackCount: number, read expiresAt: number? }

type ResourceAnchor = {
	read anchorValue: number,
	read anchorTime: number,
	read min: number,
	read max: number,
	read regenRate: number?,
}

local TAGS_DOMAIN: string = "KRF.Tags"
local RESOURCES_DOMAIN: string = "KRF.Resources"

local known: { [Types.PresentationStateDescriptor]: boolean } = table.freeze({
	[States.Tag.Active] = true,
	[States.Action.Active] = true,
	[States.Resource.Current] = true,
	[States.Actor.Model] = true,
})

local entries: { [Types.PresentationStateEntryDescriptor]: boolean } = table.freeze({
	[States.Tag.Active] = true,
	[States.Action.Active] = true,
})

local StateSources = {}

local function domainEntry(actor: ActorTypes.ActorView, domainId: string, id: string): any
	local domain: ActorTypes.DomainView? = actor:GetDomain(domainId)

	return if domain ~= nil then domain:GetState()[id] else nil
end

function StateSources.IsKnown(descriptor: any): boolean
	return type(descriptor) == "table" and known[descriptor] == true
end

function StateSources.IsEntry(descriptor: any): boolean
	return type(descriptor) == "table" and entries[descriptor] == true
end

function StateSources.Same(first: Signature, second: Signature): boolean
	if #first ~= #second then
		return false
	end

	for index: number, value in first do
		if second[index] ~= value then
			return false
		end
	end

	return true
end

function StateSources.SampleTag(actor: ActorTypes.ActorView, tagId: string): (ActorTypes.ActiveTagSnapshot?, Signature)
	local entry: TagState? = domainEntry(actor, TAGS_DOMAIN, tagId)

	if entry == nil then
		return nil, {}
	end

	return assert(actor:GetTags():GetTag(tagId), "Tag domain entry has a typed snapshot"),
		{ entry.stackCount, if entry.expiresAt ~= nil then entry.expiresAt else false }
end

function StateSources.SampleAction(
	association: Types.PresentationActionAssociation?
): (ActorTypes.ActionSnapshot?, Signature)
	local sequenceId: number? = if association ~= nil then association.sequenceId else nil

	if association == nil or sequenceId == nil then
		return nil, {}
	end

	local snapshot: ActorTypes.ActionSnapshot? = association.actor:GetActions():GetAction(sequenceId)

	if snapshot == nil or snapshot.actionId ~= association.actionId then
		return nil, {}
	end

	return snapshot, { snapshot.sequenceId }
end

function StateSources.SampleResource(
	actor: ActorTypes.ActorView,
	resourceId: string
): (ActorTypes.ResourceSnapshot?, Signature)
	local entry: ResourceAnchor? = domainEntry(actor, RESOURCES_DOMAIN, resourceId)

	if entry == nil then
		return nil, {}
	end

	return assert(actor:GetResources():GetResource(resourceId), "Resource domain entry has a typed snapshot"),
		{
			entry.anchorValue,
			entry.anchorTime,
			entry.min,
			entry.max,
			if entry.regenRate ~= nil then entry.regenRate else false,
		}
end

function StateSources.SampleModel(actor: ActorTypes.ActorView): (Model?, Signature)
	local model: Model? = actor:GetModel()

	return model, if model ~= nil then { model } else {}
end

function StateSources.IsActionActive(actor: ActorTypes.ActorView, actionId: string, sequenceId: number): boolean
	local snapshot: ActorTypes.ActionSnapshot? = actor:GetActions():GetAction(sequenceId)

	return snapshot ~= nil and snapshot.actionId == actionId
end

function StateSources.Connect(
	family: StateFamily,
	actor: ActorTypes.ActorView,
	notify: () -> ()
): { SignalTypes.Connection }
	if family == "Actor" then
		return {
			actor.OnModelChanged:Connect(function(_previous: Model?, _current: Model?): ()
				notify()
			end),
		}
	end

	local changed: SignalTypes.Connection

	if family == "Tag" then
		changed = actor:GetTags().OnStateChanged:Connect(function(_source: ActorTypes.DomainChangeSource): ()
			notify()
		end)
	elseif family == "Action" then
		changed = actor:GetActions().OnStateChanged:Connect(function(_source: ActorTypes.DomainChangeSource): ()
			notify()
		end)
	else
		changed = actor:GetResources().OnResourceChanged:Connect(function(_change: ActorTypes.ResourceViewChange): ()
			notify()
		end)
	end

	return {
		changed,
		actor.OnDomainsChanged:Connect(function(_change: ActorTypes.DomainMembershipChange): ()
			notify()
		end),
	}
end

return table.freeze(StateSources)
