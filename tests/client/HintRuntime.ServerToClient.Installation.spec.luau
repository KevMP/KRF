--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Client = require(KRF.client)
local Diagnostics = require(KRF.client.Networking.NetworkingDiagnostics)
local DiagnosticState = require(KRF.client.Networking.utils.NetworkingDiagnosticsState)
local ClientTypes = require(KRF.client.types)
local Types = require(KRF.client.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Native: ClientTypes.Dependencies = require(KRF.client.Networking.utils.NativeClientDependencies)
local Hints: Types.HintRuntime = require(KRF.client.Networking.HintRuntime)
local Receiver = require(KRF.client.Networking.utils.HintReceiver)
local Transport = require(KRF.shared.Networking.Transport)
local Schema = require(KRF.shared.Networking.Schema)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local Wire = require(KRF.shared.Networking.HintCodec)
local ProtocolUtils = require(script.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local ClientUtils = require(script.Parent.Utils.ClientTestUtils)
local TestUtils = require(script.Parent.Utils.CommandClientTestUtils)
local originalStep = Native.ObserveStep
local originalReceiver = Receiver.new
local originalLocate = Transport.Locate
local discover = Native.DiscoverTransport
local fixture: TestUtils.Fixture
local receive: ((any, ...any) -> ())?
local tick: (() -> ())?
local owner: Receiver.Runtime?
local stopped: number
local received: { Types.HintReceived }
local listener: SignalTypes.Connection?
local instances: { Instance } = {}

beforeEach(function()
	fixture = TestUtils.new()
	receive, tick, owner, stopped, received = nil, nil, nil, 0, {}

	fixture.client.transport.ConnectUnreliable = function(callback): () -> ()
		receive = callback

		return function(): ()
			stopped += 1
		end
	end

	Native.ObserveStep = function(callback): () -> ()
		tick = callback

		return function(): () end
	end

	Receiver.new = function(protocol, stream, dependencies, limits)
		local created = originalReceiver(protocol, stream, dependencies, limits)
		owner = created

		return created
	end

	listener = Hints.OnHintReceived:Connect(function(value: Types.HintReceived): ()
		table.insert(received, value)
	end)
end)

afterEach(function()
	fixture.cleanup()

	if listener ~= nil then
		listener:Disconnect()
	end

	Native.ObserveStep = originalStep
	Receiver.new = originalReceiver
	Transport.Locate = originalLocate

	for _, instance in instances do
		instance:Destroy()
	end

	instances = {}
end)

local function bootstrap(): ()
	TestUtils.start(fixture)
	local original = ProtocolUtils.manifest()

	local metadata: SharedTypes.ProtocolManifest = {
		version = original.version,
		domains = original.domains,
		hints = {
			{
				id = "Game.Look",
				code = 0,
				direction = "ServerToClient",
				target = "Actor",
				mode = "Latest",
				payload = Schema.Struct({ value = Schema.U8 }),
			},
			{
				id = "Game.Pulse",
				code = 1,
				direction = "ServerToClient",
				target = "None",
				mode = "Pulse",
				payload = Schema.U8,
			},
			{
				id = "Game.Sample",
				code = 2,
				direction = "ServerToClient",
				target = "None",
				mode = "Latest",
				payload = Schema.U8,
			},
		},
	}

	fixture.protocol = assert(Manifest.Reconstruct(metadata))
	ClientUtils.emit(fixture.client, ProtocolUtils.encode({ kind = "Bootstrap", manifest = metadata }))
	assert(owner ~= nil and receive ~= nil and tick ~= nil, "S2C consumers must install before READY")
end

local function emit(value: number, sequence: number?, handle: number?): ()
	local protocol = assert(fixture.protocol, "Expected reconstructed Hint codebooks")
	local codec = Wire.Compile(protocol, "ServerToClient")

	local record = assert(codec.EncodeRecord({
		hintCode = if handle ~= nil then 0 else if sequence ~= nil then 2 else 1,
		targetHandle = handle,
		sequence = sequence,
		payload = if handle ~= nil then { value = value } else value,
	}))

	local packet = assert(codec.Pack({ record }))
	local receiver = assert(receive, "Expected native unreliable listener")
	receiver(packet)
end

local function pump(): ()
	local step = assert(tick, "Expected native Hint pump")
	step()
end

it("installs S2C-only catalogs before READY and emits schema-owned receipts through normal consumers", function()
	bootstrap()
	emit(1)
	pump()
	expect(received).toEqual({})
	ClientUtils.acknowledge(fixture.client)
	expect(fixture.client.result).toEqual({ success = true })
	local view = TestUtils.baseline(fixture)
	local domain = assert(view:GetDomain("Game.Actions"), "Expected installed domain")
	local prior = domain:GetState()
	emit(4, 1, 7)
	emit(5)
	expect(received).toEqual({})
	pump()

	expect(received).toEqual({
		{ hintId = "Game.Look", actorView = view, payload = { value = 4 } },
		{ hintId = "Game.Pulse", payload = 5 },
	})

	expect(table.isfrozen(received[1].payload)).toBe(true)
	expect(domain:GetState()).toBe(prior)
	expect(fixture.sent).toEqual({})
end)

it("cleans retired views and old receive lifetimes and disconnects listeners exactly once", function()
	bootstrap()
	ClientUtils.acknowledge(fixture.client)
	TestUtils.baseline(fixture)
	emit(9, 9, 7)
	pump()
	local installed = assert(owner, "Expected installed Hint receiver")
	expect(installed.latestCount).toBe(1)
	TestUtils.records(fixture, { { kind = "ActorRemove", handle = 7 } })
	expect(installed.latestCount).toBe(0)
	emit(10, 10, 7)
	pump()
	expect(#received).toBe(1)
	TestUtils.baseline(fixture, 8, "ActorB")
	emit(1, 1, 8)
	pump()
	expect(#received).toBe(2)
	local oldReceive = assert(receive, "Expected retained old endpoint")
	emit(7, 7)
	Client._ResetForTests()
	Client._ResetForTests()
	expect(stopped).toBe(1)
	expect(installed.pendingBytes).toBe(0)
	expect(installed.latestCount).toBe(0)
	oldReceive(buffer.create(0))
	pump()
	expect(#received).toBe(2)
	bootstrap()
	ClientUtils.acknowledge(fixture.client)

	listener = Hints.OnHintReceived:Connect(function(value: Types.HintReceived): ()
		table.insert(received, value)
	end)

	emit(1, 1)
	pump()
	expect(#received).toBe(3)
	expect(received[3]).toEqual({ hintId = "Game.Sample", payload = 1 })
end)

it("connects and disconnects the existing native unreliable endpoint without affecting the reliable one", function()
	local inbound = Instance.new("BindableEvent")
	local barrier = Instance.new("BindableEvent")
	local root = Instance.new("Folder")
	local reliable = Instance.new("RemoteEvent")
	instances = { inbound, barrier, root, reliable }

	local owned: SharedTypes.OwnedTransport = {
		root = root,
		reliable = reliable,
		-- BindableEvent supplies the native callback shape without client-only engine capabilities.
		unreliable = { OnClientEvent = inbound.Event } :: any,
		Destroy = function(): () end,
	}

	Transport.Locate = function(): (SharedTypes.OwnedTransport?, string?)
		return owned, nil
	end

	local endpoint = assert(discover(os.clock() + 1))
	local connect = assert(endpoint.ConnectUnreliable, "Expected native unreliable observer")
	local payload: string? = nil

	local stop = connect(function(value: buffer): ()
		payload = buffer.tostring(value)
	end)

	inbound:Fire(buffer.fromstring("sample"))

	task.defer(function(): ()
		barrier:Fire()
	end)

	barrier.Event:Wait()
	expect(payload).toBe("sample")
	stop()
	stop()
	inbound:Fire(buffer.fromstring("obsolete"))

	task.defer(function(): ()
		barrier:Fire()
	end)

	barrier.Event:Wait()
	expect(payload).toBe("sample")
end)

it("reports client admission and retained packet ownership through reentrant receipt shutdown", function()
	expect(Diagnostics.GetClientSnapshot()).toBeNil()
	bootstrap()
	local aggregate = assert(DiagnosticState.Get())
	local startup = assert(Diagnostics.GetClientSnapshot())
	expect(startup.scope).toBe("Client")
	expect(startup.counters.reliableSendAttempts).toBe(2)
	expect(startup.counters.reliableLogicalRecords).toBe(0)
	emit(1)
	expect(assert(Diagnostics.GetClientSnapshot()).counters.hintPacketsRefused).toBe(1)
	ClientUtils.acknowledge(fixture.client)
	emit(2)
	local pending = assert(Diagnostics.GetClientSnapshot())
	expect(pending.counters.hintPacketsAdmitted).toBe(1)
	expect(pending.gauges.hintReceivePackets.current).toBe(1)
	expect(pending.gauges.hintReceiveBytes.current).toBe(12)
	expect(table.isfrozen(pending.gauges.hintReceiveBytes)).toBe(true)
	local checkedUnwind = false

	local disconnect = Hints.OnHintReceived:Connect(function(): ()
		Client._ResetForTests()
		expect(Diagnostics.GetClientSnapshot()).toBeNil()
		expect(aggregate:Snapshot().gauges.hintReceivePackets.current).toBe(1)
		expect(aggregate:Snapshot().gauges.hintReceiveBytes.current).toBe(12)
		checkedUnwind = true
	end)

	pump()
	disconnect:Disconnect()
	expect(checkedUnwind).toBe(true)
	expect(aggregate:Snapshot().gauges.hintReceivePackets.current).toBe(0)
	expect(aggregate:Snapshot().gauges.hintReceiveBytes.current).toBe(0)
	expect(aggregate:Snapshot().gauges.hintReceiveBytes.highWater).toBe(12)
	expect(pending.gauges.hintReceiveBytes.current).toBe(12)
	Client._ResetForTests()
	expect(aggregate:Snapshot().gauges.hintReceiveBytes.current).toBe(0)
end)
