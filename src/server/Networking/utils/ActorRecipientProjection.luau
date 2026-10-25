--!strict
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local Types = require(script.Parent.Parent.types)
local ReplicationTypes = require(script.Parent.Parent.Parent.Replication.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)

export type Projection = {
	sequence: number,
	encodedSizeBytes: number,
	retainedBytes: number,
	canonical: Types.PublicationBaseline?,
	isOwner: boolean,
	domains: { [string]: SharedNetworkingTypes.ActorDomainTruth },
	body: buffer?,
	reason: string?,
}

type BaselineCache = { sequence: number, public: Projection?, owner: Projection? }

local ActorRecipientProjection = {}
ActorRecipientProjection.__index = ActorRecipientProjection

type State = {
	publication: Types.PublicationRuntime,
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	codec: SharedNetworkingTypes.ActorStreamCodec,
	baselines: { [ActorTypes.Actor]: BaselineCache },
}

export type Runtime = typeof(setmetatable({} :: State, ActorRecipientProjection))

function ActorRecipientProjection.new(
	publication: Types.PublicationRuntime,
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	codec: SharedNetworkingTypes.ActorStreamCodec
): Runtime
	local state: State = { publication = publication, catalog = catalog, codec = codec, baselines = {} }

	return setmetatable(state, ActorRecipientProjection)
end

function ActorRecipientProjection.Anchor(
	self: Runtime,
	actor: ActorTypes.Actor,
	isOwner: boolean
): (number?, Projection?, string?)
	local captured: Types.PublicationBaseline? = self.publication:CaptureBaseline(actor, not isOwner)

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
		local encodedSizeBytes = self.publication:GetBaselineWeight(actor, not isOwner)

		-- Reserve canonical retained weight plus the largest possible recipient
		-- body before retaining either. This one charge survives materialization.
		local created: Projection = {
			sequence = captured.sequence,
			encodedSizeBytes = encodedSizeBytes,
			retainedBytes = encodedSizeBytes * 2,
			canonical = captured,
			isOwner = isOwner,
			domains = captured.domains,
			body = nil,
			reason = nil,
		}

		projected = created

		if isOwner then
			cache.owner = projected
		else
			cache.public = projected
		end
	end

	return captured.sequence, projected, nil
end

function ActorRecipientProjection.Project(
	self: Runtime,
	actor: ActorTypes.Actor,
	projected: Projection
): (number?, Projection?, string?)
	local captured = projected.canonical

	if captured ~= nil then
		local domains: { [string]: SharedNetworkingTypes.ActorDomainTruth } = {}

		for id: string, truth: Types.PublicationDomainTruth in captured.domains do
			local definition: ReplicationTypes.LoadedReplicationDomainDefinition? = self.catalog.definitionsById[id]

			if definition ~= nil and (definition.audience == "All" or projected.isOwner) then
				domains[id] = truth
			end
		end

		table.freeze(domains)
		local body: buffer?, reason: string? = self.codec.EncodeBaseline(domains)
		projected.domains, projected.body, projected.reason = domains, body, reason
		projected.canonical = nil
	end

	assert(projected ~= nil, "Expected recipient baseline projection")
	local body: buffer?, reason: string? = projected.body, projected.reason

	if body == nil then
		self:Discard(actor, projected)

		return nil, nil, reason or "InvalidActorBaseline"
	end

	return projected.sequence, projected, nil
end

function ActorRecipientProjection.Forget(self: Runtime, actor: ActorTypes.Actor): ()
	self.baselines[actor] = nil
end

-- The reusable body cache may retain only bodies still owned by a transfer.
function ActorRecipientProjection.Discard(self: Runtime, actor: ActorTypes.Actor, projection: Projection): ()
	local cache = self.baselines[actor]

	if cache == nil then
		return
	end

	if cache.public == projection then
		cache.public = nil
	end

	if cache.owner == projection then
		cache.owner = nil
	end

	if cache.public == nil and cache.owner == nil then
		self.baselines[actor] = nil
	end
end

function ActorRecipientProjection.PublicCommit(
	self: Runtime,
	commit: Types.PublicationCommit
): Types.PublicationFilteredCommit
	local cached: BaselineCache? = self.baselines[commit.actor]

	if cached ~= nil and cached.sequence < commit.sequence then
		-- In-flight transfers keep their immutable body; only reusable projections expire.
		self.baselines[commit.actor] = nil
	end

	local publicPatches: { Types.PublicationDomainPatch } = {}
	local publicEvents: { Types.PublicationEvent } = {}

	for _, patch: Types.PublicationDomainPatch in commit.patches do
		if self.catalog.definitionsById[patch.domainId].audience == "All" then
			table.insert(publicPatches, patch)
		end
	end

	for _, event: Types.PublicationEvent in commit.events do
		if self.catalog.definitionsById[event.domainId].audience == "All" then
			table.insert(publicEvents, event)
		end
	end

	table.freeze(publicPatches)
	table.freeze(publicEvents)

	local public: Types.PublicationFilteredCommit =
		table.freeze({ sequence = commit.sequence, patches = publicPatches, events = publicEvents })

	return public
end

function ActorRecipientProjection.Destroy(self: Runtime): ()
	table.clear(self.baselines)
end

return ActorRecipientProjection
