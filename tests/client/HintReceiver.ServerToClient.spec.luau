--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local PublicTypes = require(KRF.client.Actor.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Receiver = require(KRF.client.Networking.utils.HintReceiver)
local Stream = require(KRF.client.Networking.ActorStreamRuntime)
local State = require(KRF.client.Networking.utils.HintRuntimeState)
local Hints: Types.HintRuntime = require(KRF.client.Networking.HintRuntime)
local Wire = require(KRF.shared.Networking.HintCodec)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local Constants = require(KRF.shared.Networking.utils.HintConstants)
local ProtocolUtils = require(script.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local TestUtils = require(script.Parent.Utils.CommandClientTestUtils)
local fixture: TestUtils.Fixture
local stream: Types.ActorStreamRuntime?
local runtime: Receiver.Runtime
local limits: Types.HintReceiveLimits
local codec: SharedTypes.HintCodec
local protocol: SharedTypes.ClientProtocol
local ready: boolean
local now: number
local received: { Types.HintReceived }
local callback: (() -> ())?
local listener: SignalTypes.Connection?
local originalStream = Stream.new

beforeEach(function()
	fixture = TestUtils.new()
	stream, received, ready, now, callback = nil, {}, true, 100, nil

	Stream.new = function(wire, consumer, discovery, options)
		local created = originalStream(wire, consumer, discovery, options)
		stream = created

		return created
	end

	TestUtils.ready(fixture)

	local original = ProtocolUtils.manifest()

	local metadata: SharedTypes.ProtocolManifest = {
		version = original.version,
		domains = original.domains,
		hints = {
			{
				id = "Game.Input",
				code = 0,
				direction = "ClientToServer",
				target = "None",
				mode = "Pulse",
				payload = Schema.U8,
			},
			{
				id = "Game.Look",
				code = 1,
				direction = "ServerToClient",
				target = "Actor",
				mode = "Latest",
				payload = Schema.Struct({ value = Schema.U8 }),
			},
			{
				id = "Game.Pulse",
				code = 2,
				direction = "ServerToClient",
				target = "None",
				mode = "Pulse",
				payload = Schema.Optional(Schema.U8),
			},
			{
				id = "Game.Sample",
				code = 3,
				direction = "ServerToClient",
				target = "None",
				mode = "Latest",
				payload = Schema.U8,
			},
		},
	}

	protocol = assert(Manifest.Reconstruct(metadata))
	codec = Wire.Compile(protocol, "ServerToClient")
	limits = table.clone(Constants.RECEIVE) :: Types.HintReceiveLimits
	limits.maxRecords = 2

	runtime = Receiver.new(protocol, assert(stream, "Expected production Actor stream"), {
		Now = function(): number
			return now
		end,
		IsReady = function(): boolean
			return ready
		end,
		Notify = function(value: Types.HintReceived): ()
			State.Notify(value)

			if callback ~= nil then
				callback()
			end
		end,
	}, limits)

	listener = Hints.OnHintReceived:Connect(function(value: Types.HintReceived): ()
		table.insert(received, value)
	end)
end)

afterEach(function()
	runtime:Destroy()

	if listener ~= nil then
		listener:Disconnect()
	end

	fixture.cleanup()
	Stream.new = originalStream
end)

local function packet(value: number?, sequence: number?, handle: number?): buffer
	local record = assert(codec.EncodeRecord({
		hintCode = if handle ~= nil then 1 else if sequence ~= nil then 3 else 2,
		targetHandle = handle,
		sequence = sequence,
		payload = if handle ~= nil then { value = value } else value,
	}))

	local data = assert(codec.Pack({ record }))

	return data
end

it("maps only current available ActorViews and publishes frozen semantic payloads without reliable work", function()
	local view: PublicTypes.ActorView = TestUtils.baseline(fixture)
	local data = packet(7, 1, 7)
	expect((runtime:Handle(data))).toBe(true)
	expect(received).toEqual({})
	buffer.writeu8(data, buffer.len(data) - 1, 9)
	local work, delivered = runtime:Step()
	expect(work).toBe(1)
	expect(delivered).toBe(1)
	expect(received).toEqual({ { hintId = "Game.Look", actorView = view, payload = { value = 7 } } })
	expect(table.isfrozen(received[1])).toBe(true)
	expect(table.isfrozen(received[1].payload)).toBe(true)
	expect(fixture.sent).toEqual({})
	expect(view:IsAvailable()).toBe(true)
	expect(runtime.pendingBytes).toBe(0)
end)

it("suppresses duplicates and reordered Latest independently across definitions and live Actor targets", function()
	TestUtils.baseline(fixture)
	TestUtils.baseline(fixture, 8, "ActorB")
	runtime:Handle(packet(5, 5, 7))
	runtime:Handle(packet(1, 1, 8))
	runtime:Step()
	runtime:Handle(packet(4, 4, 7))
	runtime:Handle(packet(5, 5, 7))
	runtime:Step()
	runtime:Handle(packet(1, 1))
	runtime:Step()
	expect(#received).toBe(3)
	expect(received[2].payload.value).toBe(1)
	expect(received[3]).toEqual({ hintId = "Game.Sample", payload = 1 })
	expect(runtime.latestCount).toBe(3)
end)

it("keeps Pulse occurrences independent, including optional nil payloads", function()
	runtime:Handle(packet(nil))
	runtime:Handle(packet(2))
	runtime:Step()
	expect(received).toEqual({ { hintId = "Game.Pulse" }, { hintId = "Game.Pulse", payload = 2 } })
	expect(runtime.latestCount).toBe(0)
end)

it("drops queued Actor samples when the current view becomes unavailable", function()
	local view = TestUtils.baseline(fixture)
	runtime:Handle(packet(1, 1, 7))
	TestUtils.records(fixture, { { kind = "ActorHalt", handle = 7 } })
	expect(view:IsAvailable()).toBe(false)
	runtime:Step()
	expect(received).toEqual({})
	expect(runtime.latestCount).toBe(0)
	expect(fixture.sent).toEqual({})
end)

it("refuses pre-Ready traffic and malformed frames or extra arguments before retention", function()
	ready = false
	local admitted, reason = runtime:Handle(packet(1))
	expect(admitted).toBe(false)
	expect(reason).toBe("ClientNotReady")
	ready = true
	admitted, reason = runtime:Handle(false)
	expect(admitted).toBe(false)
	expect(reason).toBe("MalformedHintPacket")
	admitted, reason = runtime:Handle(packet(1), true)
	expect(admitted).toBe(false)
	expect(reason).toBe("MalformedHintPacket")
	expect(runtime.pendingBytes).toBe(0)
end)

it("drops wrong directions, unknown codes and malformed payloads without resync or notifications", function()
	local c2s = Wire.Compile(protocol)
	local record = assert(c2s.EncodeRecord({ hintCode = 0, payload = 1 }))
	local data = assert(c2s.Pack({ record }))
	runtime:Handle(data)
	data = packet(1)
	buffer.writeu16(data, 9, 999)
	runtime:Handle(data)
	runtime:Step()
	data = packet(nil)
	buffer.writeu8(data, 11, 255)
	runtime:Handle(data)
	runtime:Step()
	expect(received).toEqual({})
	expect(fixture.sent).toEqual({})
	expect(runtime.pendingBytes).toBe(0)
end)

it("bounds retained packet count and bytes and restores capacity after dispatch", function()
	limits.maxPendingPackets = 1

	local data = packet(1)
	runtime:Handle(data)
	local admitted, reason = runtime:Handle(data)
	expect(admitted).toBe(false)
	expect(reason).toBe("HintPendingFull")
	runtime:Step()
	limits.maxPendingBytes = buffer.len(data) - 1
	admitted, reason = runtime:Handle(data)
	expect(admitted).toBe(false)
	expect(reason).toBe("HintPendingFull")
	limits.maxPendingBytes = buffer.len(data)
	expect((runtime:Handle(data))).toBe(true)
	runtime:Step()
	expect(#received).toBe(2)
end)

it("counts malformed attempts against the rate budget and restores the byte budget at the window", function()
	limits.maxPackets = 2
	runtime:Handle(false)
	runtime:Handle(false)
	local admitted, reason = runtime:Handle(packet(1))
	expect(admitted).toBe(false)
	expect(reason).toBe("HintRateLimited")
	now += 1
	limits.maxBytes = 1
	admitted, reason = runtime:Handle(packet(1))
	expect(admitted).toBe(false)
	expect(reason).toBe("HintRateLimited")
	now += 1
	limits.maxBytes = 900
	expect((runtime:Handle(packet(2)))).toBe(true)
	runtime:Step()
	expect(#received).toBe(1)
end)

it("bounds attempted record work within a multi-record packet while retaining its ownership", function()
	local records: { buffer } = {}

	for value = 1, 3 do
		local record = assert(codec.EncodeRecord({ hintCode = 2, payload = value }))
		table.insert(records, record)
	end

	local data = assert(codec.Pack(records))
	runtime:Handle(data)
	local work = runtime:Step()
	expect(work).toBe(2)
	expect(#received).toBe(2)
	expect(runtime.pendingBytes).toBe(buffer.len(data))
	runtime:Step()
	expect(#received).toBe(3)
	expect(runtime.pendingBytes).toBe(0)
	expect((runtime:Step())).toBe(0)
end)

it("drops retired and unknown handles without suppressing a fresh target's first sample", function()
	local view = TestUtils.baseline(fixture)
	runtime:Handle(packet(9, 9, 7))
	runtime:Step()
	TestUtils.records(fixture, { { kind = "ActorRemove", handle = 7 } })
	runtime:ForgetActor(view)
	expect(runtime.latestCount).toBe(0)
	runtime:Handle(packet(10, 10, 7))
	runtime:Step()
	local replacement = TestUtils.baseline(fixture, 8, "ActorB")
	runtime:Handle(packet(1, 1, 8))
	runtime:Step()
	expect(#received).toBe(2)
	expect(received[2].actorView).toBe(replacement)
	expect(received[2].payload.value).toBe(1)
	expect(fixture.sent).toEqual({})
end)

it("caps live Latest metadata without eviction and permits Pulse while key capacity is full", function()
	limits.maxLatestKeys = 1

	local view = TestUtils.baseline(fixture)
	runtime:Handle(packet(1, 1, 7))
	runtime:Step()
	runtime:Handle(packet(2, 1))
	runtime:Handle(packet(3))
	runtime:Step()
	expect(#received).toBe(2)
	expect(received[2].hintId).toBe("Game.Pulse")
	runtime:ForgetActor(view)
	runtime:Handle(packet(4, 1))
	runtime:Step()
	expect(received[3].payload).toBe(4)
end)

it("isolates throwing and yielding notification seams while preserving later delivery", function()
	callback = function(): ()
		error("CosmeticFailure")
	end

	runtime:Handle(packet(1))
	runtime:Step()

	callback = function(): ()
		coroutine.yield()
	end

	runtime:Handle(packet(2))
	runtime:Step()
	callback = nil
	runtime:Handle(packet(3))
	runtime:Step()
	expect(#received).toBe(3)
	expect(runtime.pendingBytes).toBe(0)
end)

it("retains the selected packet through reentrant destruction and refuses the obsolete receiver", function()
	local during: number? = nil
	local nested: number? = nil

	callback = function(): ()
		runtime:Destroy()
		during = runtime.pendingBytes
		nested = runtime:Step()
	end

	local data = packet(1)
	runtime:Handle(data)
	runtime:Handle(packet(2))
	runtime:Step()
	expect(during).toBe(buffer.len(data))
	expect(nested).toBe(0)
	expect(runtime.pendingBytes).toBe(0)
	runtime:Destroy()
	local accepted, reason = runtime:Handle(packet(3))
	expect(accepted).toBe(false)
	expect(reason).toBe("ClientNotReady")
end)
