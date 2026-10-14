--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local Types = require(KRF.client.Networking.ActorStreamTypes)
local WireTypes = require(KRF.shared.Networking.ActorStreamTypes)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local Runtime: Types.RuntimeModule = require(KRF.client.Networking.ActorStreamRuntime)
local Codec: WireTypes.CodecModule = require(KRF.shared.Networking.ActorStreamCodec)
local Compiler: ProtocolTypes.ManifestCompiler = require(KRF.shared.Networking.ManifestCompiler)
local ProtocolUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local SchemaUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.SchemaTestUtils)

export type BaselineDelivery = {
	actor: Types.ActorRecord,
	revision: number,
	domains: { [string]: WireTypes.DomainTruth },
}
export type CommitDelivery = {
	actor: Types.ActorRecord,
	revision: number,
	patches: { WireTypes.DomainPatch },
	events: { WireTypes.Event },
}
export type Binding = { actor: Types.ActorRecord, model: Model }
export type Fixture = {
	runtime: Types.Runtime?,
	protocol: ProtocolTypes.ClientProtocol,
	codec: WireTypes.Codec,
	consumer: Types.Consumer,
	discovery: Types.Discovery,
	options: Types.Options,
	baselines: { BaselineDelivery },
	commits: { CommitDelivery },
	removed: { Types.ActorRecord },
	bound: { Binding },
	unbound: { Binding },
	faults: { string },
	candidates: { Types.Candidate },
	added: { (Types.Candidate) -> () },
	gone: { (Instance) -> () },
	instances: { Instance },
	scans: number,
}

local TestUtils = {}

function TestUtils.new(): Fixture
	local manifest: ProtocolTypes.ProtocolManifest = ProtocolUtils.manifest()
	local protocol: ProtocolTypes.ClientProtocol?, reason: string? = Compiler.Reconstruct(manifest)
	expect(reason).toBeNil()
	assert(protocol ~= nil, "Expected compiled N2 client protocol")
	local schemas: WireTypes.SchemaCatalog = {}
	for _, domain: ProtocolTypes.ManifestDomain in manifest.domains do
		schemas[domain.id] = SchemaUtils.compile(domain.state)
	end
	local fixture: Fixture = {
		runtime = nil,
		protocol = protocol,
		codec = Codec.Compile(protocol, schemas),
		consumer = {} :: Types.Consumer,
		discovery = {} :: Types.Discovery,
		options = {} :: Types.Options,
		baselines = {},
		commits = {},
		removed = {},
		bound = {},
		unbound = {},
		faults = {},
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
			actor: Types.ActorRecord,
			revision: number,
			domains: { [string]: WireTypes.DomainTruth }
		): ()
			table.insert(fixture.baselines, { actor = actor, revision = revision, domains = domains })
		end,
		OnCommitReady = function(
			actor: Types.ActorRecord,
			revision: number,
			patches: { WireTypes.DomainPatch },
			events: { WireTypes.Event }
		): ()
			table.insert(fixture.commits, { actor = actor, revision = revision, patches = patches, events = events })
		end,
		OnActorRemoved = function(actor: Types.ActorRecord): ()
			table.insert(fixture.removed, actor)
		end,
		OnModelBound = function(actor: Types.ActorRecord, model: Model): ()
			table.insert(fixture.bound, { actor = actor, model = model })
		end,
		OnModelUnbound = function(actor: Types.ActorRecord, model: Model): ()
			table.insert(fixture.unbound, { actor = actor, model = model })
		end,
	}
	fixture.discovery = {
		GetCandidates = function(): { Types.Candidate }
			fixture.scans += 1
			return table.clone(fixture.candidates)
		end,
		ObserveAdded = function(callback: (Types.Candidate) -> ()): () -> ()
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

function TestUtils.start(fixture: Fixture, withoutConsumer: boolean?): Types.Runtime
	local runtime: Types.Runtime = Runtime.new(
		fixture.codec,
		if withoutConsumer then nil else fixture.consumer,
		fixture.discovery,
		fixture.options
	)
	fixture.runtime = runtime
	return runtime
end

function TestUtils.send(fixture: Fixture, records: { WireTypes.Record }): (boolean, string?)
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

function TestUtils.establish(
	fixture: Fixture,
	handle: number?,
	actorId: string?,
	generation: number?,
	revision: number?
): ()
	local body: buffer = TestUtils.body(fixture)
	local success: boolean, reason: string? = TestUtils.send(fixture, {
		{
			kind = "BaselineBegin",
			handle = handle or 1,
			actorId = actorId or "ActorA",
			generation = generation or 1,
			totalBytes = buffer.len(body),
		},
		{ kind = "BaselineChunk", handle = handle or 1, generation = generation or 1, offset = 0, bytes = body },
		{ kind = "BaselineEnd", handle = handle or 1, generation = generation or 1, revision = revision or 1 },
	})
	expect(success).toBe(true)
	expect(reason).toBeNil()
end

function TestUtils.candidate(fixture: Fixture, actorId: string, existingModel: Model?): Types.Candidate
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

function TestUtils.add(fixture: Fixture, candidate: Types.Candidate): ()
	table.insert(fixture.candidates, candidate)
	for _, callback: (Types.Candidate) -> () in table.clone(fixture.added) do
		callback(candidate)
	end
end

function TestUtils.remove(fixture: Fixture, candidate: Types.Candidate): ()
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
