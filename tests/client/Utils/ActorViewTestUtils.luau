--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local PublicTypes = require(KRF.client.Actor.types)
local Types = require(KRF.client.Networking.ActorViewTypes)
local StreamTypes = require(KRF.client.Networking.ActorStreamTypes)
local WireTypes = require(KRF.shared.Networking.ActorStreamTypes)
local ProtocolTypes = require(KRF.shared.Networking.ProtocolTypes)
local SchemaTypes = require(KRF.shared.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Schema: SchemaTypes.Schema = require(KRF.shared.Networking.Schema)
local Runtime: Types.RuntimeModule = require(KRF.client.Networking.ActorViewRuntime)
local Stream: StreamTypes.RuntimeModule = require(KRF.client.Networking.ActorStreamRuntime)
local Codec: WireTypes.CodecModule = require(KRF.shared.Networking.ActorStreamCodec)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local Constants = require(KRF.shared.Networking.ProtocolConstants)
local SchemaUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.SchemaTestUtils)
local StreamUtils = require(script.Parent.ActorStreamTestUtils)

export type Fixture = {
	runtime: Types.Runtime,
	stream: StreamUtils.Fixture,
	manifest: ProtocolTypes.ProtocolManifest,
	schemas: WireTypes.SchemaCatalog,
	requests: { buffer },
	faults: { Types.Fault },
	connections: { SignalTypes.Connection },
}
local TestUtils = {}

function TestUtils.manifest(): ProtocolTypes.ProtocolManifest
	return {
		version = Constants.PROTOCOL_VERSION,
		domains = {
			{
				id = "Game.Counter",
				code = 0,
				state = Schema.U16,
				events = {
					{ id = "Changed", code = 0, payload = Schema.U16 },
					{ id = "Flag", code = 1, payload = Schema.Boolean },
					{ id = "Maybe", code = 2, payload = Schema.Optional(Schema.Struct({ count = Schema.U8 })) },
				},
			},
			{
				id = "Game.Owner",
				code = 1,
				state = Schema.Optional(Schema.Struct({ secret = Schema.String(16) })),
				events = {},
			},
			{
				id = "Game.Stamina",
				code = 2,
				state = Schema.Struct({
					current = Schema.U16,
					max = Schema.U16,
					details = Schema.Struct({ label = Schema.String(16), enabled = Schema.Boolean }),
					effects = Schema.Map(Schema.String(8), Schema.Struct({ stacks = Schema.U8 }), 3),
					slots = Schema.Array(Schema.Struct({ name = Schema.String(8) }), 3),
					target = Schema.Optional(Schema.Struct({ id = Schema.U16 })),
				}),
				events = {
					{
						id = "Changed",
						code = 0,
						payload = Schema.Struct({ amount = Schema.U16, history = Schema.Array(Schema.U16, 3) }),
					},
					{ id = "Depleted", code = 1, payload = Schema.Struct({ previous = Schema.U16 }) },
				},
			},
		},
	}
end

function TestUtils.truth(current: number?): { [string]: WireTypes.DomainTruth }
	return {
		["Game.Counter"] = { value = 7 },
		["Game.Owner"] = { value = { secret = "owner-only" } },
		["Game.Stamina"] = {
			value = {
				current = current or 100,
				max = 100,
				details = { label = "Stamina", enabled = true },
				effects = { Burn = { stacks = 1 }, Slow = { stacks = 2 } },
				slots = { { name = "Potion" }, { name = "Elixir" } },
			},
		},
	}
end

function TestUtils.new(onSend: ((buffer) -> ())?): Fixture
	local stream: StreamUtils.Fixture = StreamUtils.new()
	local manifest: ProtocolTypes.ProtocolManifest = TestUtils.manifest()
	local protocol: ProtocolTypes.ClientProtocol?, reason: string? = Manifest.Reconstruct(manifest)
	assert(protocol ~= nil, reason)
	local schemas: WireTypes.SchemaCatalog = {}
	for _, domain: ProtocolTypes.ManifestDomain in manifest.domains do
		schemas[domain.id] = SchemaUtils.compile(domain.state)
	end
	local requests: { buffer } = {}
	local faults: { Types.Fault } = {}
	local runtime: Types.Runtime = Runtime.new(protocol, schemas, {
		SendReliable = function(payload: buffer)
			table.insert(requests, payload)
			if onSend ~= nil then
				onSend(payload)
			end
		end,
		ReportFault = function(fault: Types.Fault)
			table.insert(faults, fault)
		end,
	})
	stream.protocol = protocol
	stream.codec = Codec.Compile(protocol, schemas)
	stream.consumer = runtime.consumer
	stream.runtime = Stream.new(stream.codec, runtime.consumer, stream.discovery, stream.options)
	return {
		runtime = runtime,
		stream = stream,
		manifest = manifest,
		schemas = schemas,
		requests = requests,
		faults = faults,
		connections = {},
	}
end

function TestUtils.send(fixture: Fixture, records: { WireTypes.Record }): ()
	local success: boolean, reason: string? = StreamUtils.send(fixture.stream, records)
	expect(reason).toBeNil()
	expect(success).toBe(true)
end

function TestUtils.baseline(
	fixture: Fixture,
	handle: number?,
	actorId: string?,
	revision: number?,
	truth: { [string]: WireTypes.DomainTruth }?,
	generation: number?
): ()
	local body: buffer?, reason: string? = fixture.stream.codec.EncodeBaseline(truth or TestUtils.truth())
	assert(body ~= nil, reason)
	local identity: string? = if generation == nil then actorId or "ActorA" else nil
	TestUtils.send(fixture, {
		{
			kind = "BaselineBegin",
			handle = handle or 1,
			actorId = identity,
			generation = generation or 1,
			totalBytes = buffer.len(body),
		},
		{ kind = "BaselineChunk", handle = handle or 1, generation = generation or 1, offset = 0, bytes = body },
		{ kind = "BaselineEnd", handle = handle or 1, generation = generation or 1, revision = revision or 10 },
	})
end

function TestUtils.view(fixture: Fixture, actorId: string?): PublicTypes.ActorView
	local view: PublicTypes.ActorView? = fixture.runtime.registry.GetActorViewById(actorId or "ActorA")
	expect(view).never.toBeNil()
	assert(view ~= nil, "A complete valid baseline must publish an ActorView")
	return view
end

function TestUtils.domain(fixture: Fixture, domainId: string?, actorId: string?): PublicTypes.DomainView
	local domain: PublicTypes.DomainView? = TestUtils.view(fixture, actorId):GetDomain(domainId or "Game.Stamina")
	expect(domain).never.toBeNil()
	assert(domain ~= nil, "Expected recipient-visible DomainView")
	return domain
end

function TestUtils.actor(fixture: Fixture, handle: number?): StreamTypes.ActorRecord
	assert(fixture.stream.runtime ~= nil, "Expected N4 runtime")
	local actor: StreamTypes.ActorRecord? = fixture.stream.runtime:GetByHandle(handle or 1)
	assert(actor ~= nil, "Expected N4 identity")
	return actor
end

function TestUtils.patch(current: number): WireTypes.DomainPatch
	return {
		domainId = "Game.Stamina",
		patch = { kind = "Struct", fields = { current = { kind = "Replace", value = current } } },
	}
end

function TestUtils.commit(
	fixture: Fixture,
	revision: number,
	patches: { WireTypes.DomainPatch }?,
	events: { WireTypes.Event }?,
	handle: number?
): ()
	TestUtils.send(fixture, {
		{
			kind = "Commit",
			handle = handle or 1,
			revision = revision,
			patches = patches or {},
			events = events or {},
		},
	})
end

function TestUtils.destroy(fixture: Fixture): ()
	for _, connection: SignalTypes.Connection in fixture.connections do
		connection:Disconnect()
	end
	StreamUtils.destroy(fixture.stream)
	fixture.runtime:Destroy()
end

return TestUtils
