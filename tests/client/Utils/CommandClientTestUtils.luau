--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ClientTypes = require(KRF.client.types)
local NetworkingTypes = require(KRF.client.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local PublicTypes = require(KRF.client.Actor.types)
local Client: ClientTypes.Client = require(KRF.client)
local Native: ClientTypes.Dependencies = require(KRF.client.Networking.utils.NativeClientDependencies)
local Discovery: NetworkingTypes.ActorModelDiscoveryModule = require(KRF.client.Networking.utils.ActorModelDiscovery)
local Registry: PublicTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local Consumer = require(KRF.client.Networking.utils.ActorStreamConsumer)
local Codec: SharedTypes.ProtocolCodec = require(KRF.shared.Networking.ProtocolCodec)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local ClientUtils = require(script.Parent.ClientTestUtils)
local StreamUtils = require(script.Parent.ActorStreamTestUtils)
local ProtocolUtils = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local CommandCodec = require(KRF.shared.Networking.CommandCodec)

export type Fixture = {
	client: ClientUtils.Fixture,
	stream: StreamUtils.Fixture,
	sent: { buffer },
	cleanup: () -> (),
	protocol: SharedTypes.ClientProtocol?,
	-- Runs before a non-handshake packet is recorded, simulating transport reentrancy.
	beforeSend: ((buffer) -> ())?,
}

local TestUtils = {}

function TestUtils.new(): Fixture
	Client._ResetForTests()
	Consumer.Install(nil)
	local client: ClientUtils.Fixture = ClientUtils.new()
	local stream: StreamUtils.Fixture = StreamUtils.new()
	local sent: { buffer } = {}
	local fixture: Fixture
	local originalNow: typeof(Native.Now) = Native.Now
	local originalDiscover: typeof(Native.DiscoverTransport) = Native.DiscoverTransport
	local originalSchedule: typeof(Native.ScheduleTimeout) = Native.ScheduleTimeout
	local originalResume: typeof(Native.Resume) = Native.Resume
	local originalDiscovery: typeof(Discovery.new) = Discovery.new
	local sendHandshake: (buffer) -> () = client.transport.SendReliable

	client.transport.SendReliable = function(payload: buffer): ()
		local message: SharedTypes.ProtocolMessage? = Codec.Decode(payload)

		if message ~= nil and (message.kind == "Hello" or message.kind == "Ready") then
			sendHandshake(payload)
		else
			if fixture.beforeSend ~= nil then
				fixture.beforeSend(payload)
			end

			table.insert(sent, payload)
		end
	end

	Native.Now = client.dependencies.Now
	Native.DiscoverTransport = client.dependencies.DiscoverTransport
	Native.ScheduleTimeout = client.dependencies.ScheduleTimeout
	Native.Resume = client.dependencies.Resume

	Discovery.new = function(_root: Instance?): NetworkingTypes.ActorModelDiscoveryAdapter
		return {
			GetCandidates = stream.discovery.GetCandidates,
			ObserveAdded = stream.discovery.ObserveAdded,
			ObserveRemoved = stream.discovery.ObserveRemoved,
			Destroy = function(): () end,
		}
	end

	local created: Fixture = {
		client = client,
		stream = stream,
		sent = sent,
		cleanup = function(): ()
			Client._ResetForTests()
			Consumer.Install(nil)

			if client.initThread ~= nil and coroutine.status(client.initThread) ~= "dead" then
				coroutine.close(client.initThread)
			end

			Native.Now = originalNow
			Native.DiscoverTransport = originalDiscover
			Native.ScheduleTimeout = originalSchedule
			Native.Resume = originalResume
			Discovery.new = originalDiscovery
			StreamUtils.destroy(stream)
		end,
	}

	fixture = created

	return created
end

function TestUtils.start(fixture: Fixture, config: ClientTypes.ClientInitConfig?): ()
	-- Use the production installer and real ActorStream/ActorView owners.
	fixture.client.initThread = coroutine.create(function(): ()
		local success: boolean, failure: ClientTypes.StartupFailure? = Client.Init(config)
		fixture.client.result = { success = success, failure = failure }
	end)

	local completed: boolean, reason: any = coroutine.resume(fixture.client.initThread :: thread)
	assert(completed, tostring(reason))
end

function TestUtils.bootstrap(fixture: Fixture, commands: { SharedTypes.ManifestCommand }?): ()
	local metadata: any = ProtocolUtils.manifest()

	metadata.commands = commands
		or {
			{ id = "Game.Interact", code = 0, target = "Actor", request = Schema.Struct({ choice = Schema.U8 }) },
			{ id = "Game.Ping", code = 1, target = "None" },
		}

	local protocol: SharedTypes.ClientProtocol?, compileReason: string? = Manifest.Reconstruct(metadata)
	assert(protocol ~= nil, compileReason)
	fixture.protocol = protocol

	local payload: buffer?, reason: string? = Codec.Encode({ kind = "Bootstrap", manifest = metadata })
	assert(payload ~= nil, reason)
	ClientUtils.emit(fixture.client, payload)
end

function TestUtils.ready(
	fixture: Fixture,
	config: ClientTypes.ClientInitConfig?,
	commands: { SharedTypes.ManifestCommand }?
): ()
	TestUtils.start(fixture, config)
	TestUtils.bootstrap(fixture, commands)
	ClientUtils.acknowledge(fixture.client)
	assert(fixture.client.result ~= nil and fixture.client.result.success, "Expected normal READY startup")
end

function TestUtils.result(
	fixture: Fixture,
	id: number,
	status: "Accepted" | "Rejected" | "Unknown",
	reason: string?,
	commandId: string?
): ()
	local protocol: SharedTypes.ClientProtocol? = fixture.protocol
	assert(protocol ~= nil and protocol.commandsById ~= nil, "Expected reconstructed command codebook")

	local payload: buffer?, encodeReason: string? = CommandCodec.Compile(protocol).EncodeResult({
		commandCode = protocol.commandsById[commandId or "Game.Ping"].code,
		requestId = id,
		status = status,
		reason = reason,
	})

	assert(payload ~= nil, encodeReason)
	ClientUtils.emit(fixture.client, payload)
end

function TestUtils.records(fixture: Fixture, records: { SharedTypes.ActorStreamRecord }): ()
	local payload: buffer?, reason: string? = fixture.stream.codec.Encode(records)
	assert(payload ~= nil, reason)
	ClientUtils.emit(fixture.client, payload)
end

function TestUtils.baseline(fixture: Fixture, handle: number?, actorId: string?): PublicTypes.ActorView
	local body: buffer = StreamUtils.body(fixture.stream)

	TestUtils.records(fixture, {
		{
			kind = "BaselineBegin",
			handle = handle or 7,
			actorId = actorId or "ActorA",
			generation = 1,
			totalBytes = buffer.len(body),
		},
		{ kind = "BaselineChunk", handle = handle or 7, generation = 1, offset = 0, bytes = body },
		{ kind = "BaselineEnd", handle = handle or 7, generation = 1, revision = 1 },
	})

	local view: PublicTypes.ActorView? = Registry.GetActorViewById(actorId or "ActorA")
	assert(view ~= nil, "Real Actor baseline must install the registry-owned view")

	return view
end

return TestUtils
