--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)
local PublicationTypes = require(script.Parent.PublicationTypes)
local ReplicationTypes = require(script.Parent.Parent.Replication.types)
local WireTypes = require(script.Parent.Parent.Parent.shared.Networking.ActorStreamTypes)

export type Projection = { domains: { [string]: WireTypes.DomainTruth }, body: buffer?, reason: string? }
type BaselineCache = { sequence: number, public: Projection?, owner: Projection? }
local ActorRecipientProjection = {}
ActorRecipientProjection.__index = ActorRecipientProjection

type State = {
	publication: PublicationTypes.Runtime,
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	codec: WireTypes.Codec,
	baselines: { [ActorTypes.Actor]: BaselineCache },
}
export type Runtime = typeof(setmetatable({} :: State, ActorRecipientProjection))

function ActorRecipientProjection.new(
	publication: PublicationTypes.Runtime,
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	codec: WireTypes.Codec
): Runtime
	local state: State = { publication = publication, catalog = catalog, codec = codec, baselines = {} }
	return setmetatable(state, ActorRecipientProjection)
end

function ActorRecipientProjection.Capture(
	self: Runtime,
	actor: ActorTypes.Actor,
	isOwner: boolean
): (number?, Projection?, string?)
	local captured: PublicationTypes.Baseline? = self.publication:CaptureBaseline(actor)
	if captured == nil then
		return nil, nil, "ActorBaselineMissing"
	end
	local cache: BaselineCache? = self.baselines[actor]
	if cache == nil or cache.sequence ~= captured.sequence then
		local created: BaselineCache = { sequence = captured.sequence, public = nil, owner = nil }
		cache = created
		self.baselines[actor] = cache
	end
	assert(cache ~= nil, "Expected canonical baseline cache")
	local projected: Projection? = if isOwner then cache.owner else cache.public
	if projected == nil then
		local domains: { [string]: WireTypes.DomainTruth } = {}
		for id: string, truth: PublicationTypes.DomainTruth in captured.domains do
			local definition: ReplicationTypes.LoadedReplicationDomainDefinition? = self.catalog.definitionsById[id]
			if definition ~= nil and (definition.audience == "All" or isOwner) then
				domains[id] = truth
			end
		end
		table.freeze(domains)
		local body: buffer?, reason: string? = self.codec.EncodeBaseline(domains)
		local created: Projection = { domains = domains, body = body, reason = reason }
		projected = created
		if isOwner then
			cache.owner = projected
		else
			cache.public = projected
		end
	end
	assert(projected ~= nil, "Expected recipient baseline projection")
	local body: buffer?, reason: string? = projected.body, projected.reason
	if body == nil then
		return nil, nil, reason or "InvalidActorBaseline"
	end
	return captured.sequence, projected, nil
end

function ActorRecipientProjection.Forget(self: Runtime, actor: ActorTypes.Actor): ()
	self.baselines[actor] = nil
end

function ActorRecipientProjection.PublicCommit(
	self: Runtime,
	commit: PublicationTypes.Commit
): PublicationTypes.FilteredCommit
	local cached: BaselineCache? = self.baselines[commit.actor]
	if cached ~= nil and cached.sequence < commit.sequence then
		-- In-flight transfers keep their immutable body; only reusable projections expire.
		self.baselines[commit.actor] = nil
	end
	local publicPatches: { PublicationTypes.DomainPatch } = {}
	local publicEvents: { PublicationTypes.Event } = {}
	for _, patch: PublicationTypes.DomainPatch in commit.patches do
		if self.catalog.definitionsById[patch.domainId].audience == "All" then
			table.insert(publicPatches, patch)
		end
	end
	for _, event: PublicationTypes.Event in commit.events do
		if self.catalog.definitionsById[event.domainId].audience == "All" then
			table.insert(publicEvents, event)
		end
	end
	table.freeze(publicPatches)
	table.freeze(publicEvents)
	local public: PublicationTypes.FilteredCommit =
		table.freeze({ sequence = commit.sequence, patches = publicPatches, events = publicEvents })
	return public
end

function ActorRecipientProjection.Destroy(self: Runtime): ()
	table.clear(self.baselines)
end

return ActorRecipientProjection
