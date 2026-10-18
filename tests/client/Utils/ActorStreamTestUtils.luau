--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local ClientNetworkingTypes = require(KRF.client.Networking.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Runtime: ClientNetworkingTypes.ActorStreamRuntimeModule = require(KRF.client.Networking.ActorStreamRuntime)
local Codec: SharedNetworkingTypes.ActorStreamCodecModule = require(KRF.shared.Networking.ActorStreamCodec)
local Compiler: SharedNetworkingTypes.ManifestCompiler = require(KRF.shared.Networking.ManifestCompiler)
local ProtocolUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local SchemaUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.SchemaTestUtils)

export type BaselineDelivery = {
	actor: ClientNetworkingTypes.ActorStreamRecord,
	revision: number,
	domains: { [string]: SharedNetworkingTypes.ActorDomainTruth },
}

export type CommitDelivery = {
	actor: ClientNetworkingTypes.ActorStreamRecord,
	revision: number,
	patches: { SharedNetworkingTypes.ActorDomainPatch },
	events: { SharedNetworkingTypes.ActorEvent },
}

export type Binding = { actor: ClientNetworkingTypes.ActorStreamRecord, model: Model }
export type ActorFault = { actor: ClientNetworkingTypes.ActorStreamRecord, reason: string }

export type Fixture = {
	runtime: ClientNetworkingTypes.ActorStreamRuntime?,
	protocol: SharedNetworkingTypes.ClientProtocol,
	codec: SharedNetworkingTypes.ActorStreamCodec,
	consumer: ClientNetworkingTypes.ActorStreamConsumer,
	discovery: ClientNetworkingTypes.ActorModelDiscovery,
	options: ClientNetworkingTypes.ActorStreamOptions,
	baselines: { BaselineDelivery },
	commits: { CommitDelivery },
	halted: { ClientNetworkingTypes.ActorStreamRecord },
	removed: { ClientNetworkingTypes.ActorStreamRecord },
	bound: { Binding },
	unbound: { Binding },
	faults: { string },
	actorFaults: { ActorFault },
	candidates: { ClientNetworkingTypes.ActorModelCandidate },
	added: { (ClientNetworkingTypes.ActorModelCandidate) -> () },
	gone: { (Instance) -> () },
	instances: { Instance },
	scans: number,
}

local TestUtils = {}

function TestUtils.new(): Fixture
	local manifest: SharedNetworkingTypes.ProtocolManifest = ProtocolUtils.manifest()
	local protocol: SharedNetworkingTypes.ClientProtocol?, reason: string? = Compiler.Reconstruct(manifest)
	expect(reason).toBeNil()
	assert(protocol ~= nil, "Expected compiled N2 client protocol")
	local schemas: SharedNetworkingTypes.ActorSchemaCatalog = {}

	for _, domain: SharedNetworkingTypes.ManifestDomain in manifest.domains do
		schemas[domain.id] = SchemaUtils.compile(domain.state)
	end

	local fixture: Fixture = {
		runtime = nil,
		protocol = protocol,
		codec = Codec.Compile(protocol, schemas),
		consumer = {} :: ClientNetworkingTypes.ActorStreamConsumer,
		discovery = {} :: ClientNetworkingTypes.ActorModelDiscovery,
		options = {} :: ClientNetworkingTypes.ActorStreamOptions,
		baselines = {},
		commits = {},
		halted = {},
		removed = {},
		bound = {},
		unbound = {},
		faults = {},
		actorFaults = {},
		candidates = {},
		added = {},
		gone = {},
		instances = {},
		scans = 0,
	}

	fixture.options = {
		maxBaselineBytes = 512,
		maxPendingBaselines = 4,
		ReportFault = function(fault: string): ()
			table.insert(fixture.faults, fault)
		end,
	}

	fixture.consumer = {
		OnBaselineReady = function(
			actor: ClientNetworkingTypes.ActorStreamRecord,
			revision: number,
			domains: { [string]: SharedNetworkingTypes.ActorDomainTruth }
		): ()
			table.insert(fixture.baselines, { actor = actor, revision = revision, domains = domains })
		end,
		OnCommitReady = function(
			actor: ClientNetworkingTypes.ActorStreamRecord,
			revision: number,
			patches: { SharedNetworkingTypes.ActorDomainPatch },
			events: { SharedNetworkingTypes.ActorEvent }
		): ()
			table.insert(fixture.commits, { actor = actor, revision = revision, patches = patches, events = events })
		end,
		OnActorHalted = function(actor: ClientNetworkingTypes.ActorStreamRecord): ()
			table.insert(fixture.halted, actor)
		end,
		OnActorFault = function(actor: ClientNetworkingTypes.ActorStreamRecord, fault: string): ()
			table.insert(fixture.actorFaults, { actor = actor, reason = fault })
		end,
		OnActorRemoved = function(actor: ClientNetworkingTypes.ActorStreamRecord): ()
			table.insert(fixture.removed, actor)
		end,
		OnModelBound = function(actor: ClientNetworkingTypes.ActorStreamRecord, model: Model): ()
			table.insert(fixture.bound, { actor = actor, model = model })
		end,
		OnModelUnbound = function(actor: ClientNetworkingTypes.ActorStreamRecord, model: Model): ()
			table.insert(fixture.unbound, { actor = actor, model = model })
		end,
	}

	fixture.discovery = {
		GetCandidates = function(): { ClientNetworkingTypes.ActorModelCandidate }
			fixture.scans += 1

			return table.clone(fixture.candidates)
		end,
		ObserveAdded = function(callback: (ClientNetworkingTypes.ActorModelCandidate) -> ()): () -> ()
			table.insert(fixture.added, callback)

			return function(): ()
				local index: number? = table.find(fixture.added, callback)

				if index ~= nil then
					table.remove(fixture.added, index)
				end
			end
		end,
		ObserveRemoved = function(callback: (Instance) -> ()): () -> ()
			table.insert(fixture.gone, callback)

			return function(): ()
				local index: number? = table.find(fixture.gone, callback)

				if index ~= nil then
					table.remove(fixture.gone, index)
				end
			end
		end,
	}

	return fixture
end

function TestUtils.start(fixture: Fixture, withoutConsumer: boolean?): ClientNetworkingTypes.ActorStreamRuntime
	local runtime: ClientNetworkingTypes.ActorStreamRuntime = Runtime.new(
		fixture.codec,
		if withoutConsumer then nil else fixture.consumer,
		fixture.discovery,
		fixture.options
	)

	fixture.runtime = runtime

	return runtime
end

function TestUtils.send(fixture: Fixture, records: { SharedNetworkingTypes.ActorStreamRecord }): (boolean, string?)
	assert(fixture.runtime ~= nil, "Expected client stream")
	local payload: buffer?, reason: string? = fixture.codec.Encode(records)
	expect(reason).toBeNil()
	assert(payload ~= nil, "Expected Actor packet")

	return fixture.runtime:Handle(payload)
end

function TestUtils.body(fixture: Fixture): buffer
	local body: buffer?, reason: string? = fixture.codec.EncodeBaseline({
		["Game.Actions"] = { value = { active = false, mode = "Idle" } },
		["Game.Inventory"] = { value = { "Potion" } },
	})

	expect(reason).toBeNil()
	assert(body ~= nil, "Expected baseline body")

	return body
end

local function deliverBaseline(
	fixture: Fixture,
	handle: number,
	actorId: string?,
	generation: number,
	revision: number
): ()
	local body: buffer = TestUtils.body(fixture)

	local success: boolean, reason: string? = TestUtils.send(fixture, {
		{
			kind = "BaselineBegin",
			handle = handle,
			actorId = actorId,
			generation = generation,
			totalBytes = buffer.len(body),
		},
		{ kind = "BaselineChunk", handle = handle, generation = generation, offset = 0, bytes = body },
		{ kind = "BaselineEnd", handle = handle, generation = generation, revision = revision },
	})

	expect(success).toBe(true)
	expect(reason).toBeNil()
end

function TestUtils.establish(
	fixture: Fixture,
	handle: number?,
	actorId: string?,
	generation: number?,
	revision: number?
): ()
	deliverBaseline(fixture, handle or 1, actorId or "ActorA", generation or 1, revision or 1)
end

function TestUtils.replace(fixture: Fixture, handle: number, generation: number, revision: number): ()
	deliverBaseline(fixture, handle, nil, generation, revision)
end

function TestUtils.candidate(
	fixture: Fixture,
	actorId: string,
	existingModel: Model?
): ClientNetworkingTypes.ActorModelCandidate
	local model: Model = existingModel or Instance.new("Model")

	if existingModel == nil then
		table.insert(fixture.instances, model)
	end

	local marker: StringValue = Instance.new("StringValue")
	marker.Value = actorId
	marker.Parent = model

	-- Candidate adapters keep the marker's actual class/name/tag an implementation detail.
	return { marker = marker, model = model, actorId = actorId }
end

function TestUtils.add(fixture: Fixture, candidate: ClientNetworkingTypes.ActorModelCandidate): ()
	table.insert(fixture.candidates, candidate)

	for _, callback: (ClientNetworkingTypes.ActorModelCandidate) -> () in table.clone(fixture.added) do
		callback(candidate)
	end
end

function TestUtils.remove(fixture: Fixture, candidate: ClientNetworkingTypes.ActorModelCandidate): ()
	local index: number? = table.find(fixture.candidates, candidate)

	if index ~= nil then
		table.remove(fixture.candidates, index)
	end

	for _, callback: (Instance) -> () in table.clone(fixture.gone) do
		callback(candidate.marker)
	end
end

function TestUtils.destroy(fixture: Fixture): ()
	if fixture.runtime ~= nil then
		fixture.runtime:Destroy()
	end

	for _, instance: Instance in fixture.instances do
		instance:Destroy()
	end
end

return TestUtils
