--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local PublicTypes = require(KRF.client.Actor.types)
local ClientNetworkingTypes = require(KRF.client.Networking.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Runtime: ClientNetworkingTypes.ActorViewRuntimeModule = require(KRF.client.Networking.ActorViewRuntime)
local Stream: ClientNetworkingTypes.ActorStreamRuntimeModule = require(KRF.client.Networking.ActorStreamRuntime)
local Codec: SharedNetworkingTypes.ActorStreamCodecModule = require(KRF.shared.Networking.ActorStreamCodec)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local SchemaUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.SchemaTestUtils)
local StreamUtils = require(script.Parent.ActorStreamTestUtils)

export type Timer = { due: number, callback: () -> (), cancelled: boolean, fired: boolean }
export type Clock = { now: number, timers: { Timer } }
export type Fixture = {
	clock: Clock,
	runtime: ClientNetworkingTypes.ActorViewRuntime,
	stream: StreamUtils.Fixture,
	manifest: SharedNetworkingTypes.ProtocolManifest,
	schemas: SharedNetworkingTypes.ActorSchemaCatalog,
	requests: { buffer },
	faults: { ClientNetworkingTypes.ActorViewFault },
	connections: { SignalTypes.Connection },
}
local TestUtils = {}

function TestUtils.manifest(): SharedNetworkingTypes.ProtocolManifest
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

function TestUtils.truth(current: number?): { [string]: SharedNetworkingTypes.ActorDomainTruth }
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

function TestUtils.new(onSend: ((buffer) -> ())?, manifestOverride: SharedNetworkingTypes.ProtocolManifest?): Fixture
	local stream: StreamUtils.Fixture = StreamUtils.new()
	local manifest: SharedNetworkingTypes.ProtocolManifest = manifestOverride or TestUtils.manifest()
	local protocol: SharedNetworkingTypes.ClientProtocol?, reason: string? = Manifest.Reconstruct(manifest)
	assert(protocol ~= nil, reason)
	local schemas: SharedNetworkingTypes.ActorSchemaCatalog = {}
	for _, domain: SharedNetworkingTypes.ManifestDomain in manifest.domains do
		schemas[domain.id] = SchemaUtils.compile(domain.state)
	end
	local requests: { buffer } = {}
	local faults: { ClientNetworkingTypes.ActorViewFault } = {}
	local clock: Clock = { now = 0, timers = {} }
	local runtime: ClientNetworkingTypes.ActorViewRuntime = Runtime.new(protocol, schemas, {
		Now = function(): number
			return clock.now
		end,
		ScheduleTimeout = function(seconds: number, callback: () -> ()): () -> ()
			local timer: Timer = { due = clock.now + seconds, callback = callback, cancelled = false, fired = false }
			table.insert(clock.timers, timer)
			return function()
				timer.cancelled = true
			end
		end,
		SendReliable = function(payload: buffer)
			table.insert(requests, payload)
			if onSend ~= nil then
				onSend(payload)
			end
		end,
		ReportFault = function(fault: ClientNetworkingTypes.ActorViewFault)
			table.insert(faults, fault)
		end,
	})
	stream.protocol = protocol
	stream.codec = Codec.Compile(protocol, schemas)
	stream.consumer = runtime.consumer
	stream.runtime = Stream.new(stream.codec, runtime.consumer, stream.discovery, stream.options)
	return {
		clock = clock,
		runtime = runtime,
		stream = stream,
		manifest = manifest,
		schemas = schemas,
		requests = requests,
		faults = faults,
		connections = {},
	}
end

function TestUtils.advance(fixture: Fixture, seconds: number): ()
	local target: number = fixture.clock.now + seconds
	while true do
		local nextTimer: Timer? = nil
		for _, timer: Timer in fixture.clock.timers do
			if not timer.cancelled and not timer.fired and timer.due <= target then
				if nextTimer == nil or timer.due < nextTimer.due then
					nextTimer = timer
				end
			end
		end
		if nextTimer == nil then
			break
		end
		fixture.clock.now = nextTimer.due
		nextTimer.fired = true
		nextTimer.callback()
	end
	fixture.clock.now = target
end

function TestUtils.send(fixture: Fixture, records: { SharedNetworkingTypes.ActorStreamRecord }): ()
	local success: boolean, reason: string? = StreamUtils.send(fixture.stream, records)
	expect(reason).toBeNil()
	expect(success).toBe(true)
end

function TestUtils.baseline(
	fixture: Fixture,
	handle: number?,
	actorId: string?,
	revision: number?,
	truth: { [string]: SharedNetworkingTypes.ActorDomainTruth }?,
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

function TestUtils.actor(fixture: Fixture, handle: number?): ClientNetworkingTypes.ActorStreamRecord
	assert(fixture.stream.runtime ~= nil, "Expected N4 runtime")
	local actor: ClientNetworkingTypes.ActorStreamRecord? = fixture.stream.runtime:GetByHandle(handle or 1)
	assert(actor ~= nil, "Expected N4 identity")
	return actor
end

function TestUtils.patch(current: number): SharedNetworkingTypes.ActorDomainPatch
	return {
		domainId = "Game.Stamina",
		patch = { kind = "Struct", fields = { current = { kind = "Replace", value = current } } },
	}
end

function TestUtils.commit(
	fixture: Fixture,
	revision: number,
	patches: { SharedNetworkingTypes.ActorDomainPatch }?,
	events: { SharedNetworkingTypes.ActorEvent }?,
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
