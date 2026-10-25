--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Client = require(KRF.client)
local ClientTypes = require(KRF.client.types)
local Types = require(KRF.client.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Native: ClientTypes.Dependencies = require(KRF.client.Networking.utils.NativeClientDependencies)
local Hints: Types.HintRuntime = require(KRF.client.Networking.HintRuntime)
local State = require(KRF.client.Networking.utils.HintRuntimeState)
local Wire = require(KRF.shared.Networking.HintCodec)
local RuntimeModule = require(KRF.client.Networking.ClientHintRuntime)
local Transport = require(KRF.shared.Networking.Transport)
local originalDiscover = Native.DiscoverTransport
local originalLocate = Transport.Locate
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local ProtocolUtils = require(script.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local ClientUtils = require(script.Parent.Utils.ClientTestUtils)
local TestUtils = require(script.Parent.Utils.CommandClientTestUtils)
local fixture: TestUtils.Fixture
local sent: { buffer }
local tick: (() -> ())?
local stopCount: number
local originalStep = Native.ObserveStep

beforeEach(function()
	fixture = TestUtils.new()
	sent, tick, stopCount = {}, nil, 0

	fixture.client.transport.SendUnreliable = function(payload: buffer): ()
		table.insert(sent, payload)
	end

	Native.ObserveStep = function(callback: () -> ()): () -> ()
		tick = callback

		return function(): ()
			stopCount += 1
		end
	end
end)

afterEach(function()
	fixture.cleanup()
	Native.ObserveStep = originalStep
	Transport.Locate = originalLocate
end)

local function ready(): any
	TestUtils.start(fixture)

	local metadata: any = ProtocolUtils.manifest()

	metadata.hints = {
		{
			id = "Game.Look",
			code = 0,
			direction = "ClientToServer",
			target = "Actor",
			mode = "Latest",
			payload = Schema.Struct({ value = Schema.U8 }),
		},
		{
			id = "Game.Pulse",
			code = 1,
			direction = "ClientToServer",
			target = "None",
			mode = "Pulse",
			payload = Schema.U8,
		},
		{
			id = "Game.Server",
			code = 2,
			direction = "ServerToClient",
			target = "None",
			mode = "Pulse",
			payload = Schema.U8,
		},
		{
			id = "Game.Large",
			code = 3,
			direction = "ClientToServer",
			target = "None",
			mode = "Latest",
			payload = Schema.String(800),
		},
		{
			id = "Game.Sample",
			code = 4,
			direction = "ClientToServer",
			target = "None",
			mode = "Latest",
			payload = Schema.U8,
		},
	}

	fixture.protocol = assert(Manifest.Reconstruct(metadata))
	ClientUtils.emit(fixture.client, ProtocolUtils.encode({ kind = "Bootstrap", manifest = metadata }))
	ClientUtils.acknowledge(fixture.client)
	expect(fixture.client.result).toEqual({ success = true })

	return assert(State.Get(), "Expected installed Hint owner")
end

local function flush(): ()
	assert(tick ~= nil, "Expected native Hint pump installation")
	tick()
end

local function records(): { SharedTypes.HintRecord }
	local codec = Wire.Compile(assert(fixture.protocol, "Expected installed protocol"))
	local result: { SharedTypes.HintRecord } = {}

	for _, packet in sent do
		local cursor = assert(codec.Open(packet))

		while cursor.remaining > 0 do
			local record = assert(codec.Read(cursor))
			table.insert(result, record)
		end
	end

	return result
end

it("fails before initialization and READY without sending traffic or allocating requests", function()
	local accepted, reason = Hints.Send("Game.Pulse", nil, 1)
	expect(accepted).toBe(false)
	expect(reason).toBe("ClientNotReady")
	TestUtils.start(fixture)
	accepted, reason = Hints.Send("Game.Pulse", nil, 1)
	expect(accepted).toBe(false)
	expect(reason).toBe("ClientNotReady")
	expect(sent).toEqual({})
end)

it("installs a frozen Send facade and validates direction, targets and payloads locally", function()
	ready()
	local view = TestUtils.baseline(fixture)

	for _, request: any in
		{
			{ id = "Game.Unknown", reason = "UnknownHint" },
			{ id = "Game.Server", payload = 1, reason = "HintDirectionMismatch" },
			{ id = "Game.Look", payload = { value = 1 }, reason = "ActorViewUnavailable" },
			{ id = "Game.Pulse", actor = view, payload = 1, reason = "UnexpectedActorTarget" },
		}
	do
		local accepted, reason = Hints.Send(request.id, request.actor, request.payload)
		expect(accepted).toBe(false)
		expect(reason).toBe(request.reason)
	end

	local accepted, reason = Hints.Send("Game.Look", view, { value = 256 })
	expect(accepted).toBe(false)
	expect(type(reason)).toBe("string")
	expect(table.isfrozen(Hints)).toBe(true)
	expect(sent).toEqual({})
end)

it("coalesces Latest before transport, owns the encoded sample and preserves independent Pulse occurrences", function()
	local runtime = ready()
	local view = TestUtils.baseline(fixture)
	local payload = { value = 1 }
	expect((Hints.Send("Game.Look", view, payload))).toBe(true)
	payload.value = 2
	expect((Hints.Send("Game.Look", view, payload))).toBe(true)
	payload.value = 9
	expect((Hints.Send("Game.Pulse", nil, 3))).toBe(true)
	expect((Hints.Send("Game.Pulse", nil, 4))).toBe(true)
	expect(sent).toEqual({})
	flush()
	expect(#sent).toBe(1)

	expect(records()).toEqual({
		{ hintCode = 0, targetHandle = 7, sequence = 2, payload = { value = 2 } },
		{ hintCode = 1, payload = 3 },
		{ hintCode = 1, payload = 4 },
	})

	expect(runtime.pendingCount).toBe(0)
	expect(runtime.pendingBytes).toBe(0)
	expect(fixture.sent).toEqual({})
end)

it("bounds Pulse history and per-pump work while retaining capacity for coalesced Latest", function()
	local runtime = ready()
	runtime.limits.maxPending = 2
	runtime.limits.maxRecords = 1
	expect((Hints.Send("Game.Pulse", nil, 1))).toBe(true)
	expect((Hints.Send("Game.Pulse", nil, 2))).toBe(true)
	local accepted, reason = Hints.Send("Game.Pulse", nil, 3)
	expect(accepted).toBe(false)
	expect(reason).toBe("HintPendingFull")
	flush()
	expect(#records()).toBe(1)
	flush()
	expect(#records()).toBe(2)
	expect(runtime.pendingBytes).toBe(0)
end)

it("bounds attempts and bytes before repeated encoding and recovers after the rate window", function()
	local runtime = ready()
	runtime.limits.maxAttempts = 2
	expect((Hints.Send("Game.Pulse", nil, 1))).toBe(true)
	expect((Hints.Send("Game.Pulse", nil, 2))).toBe(true)
	local accepted, reason = Hints.Send("Game.Pulse", nil, 3)
	expect(accepted).toBe(false)
	expect(reason).toBe("HintRateLimited")

	runtime.dependencies.Now = function(): number
		return 101
	end

	expect((Hints.Send("Game.Pulse", nil, 3))).toBe(true)
end)

it("never wraps Latest sequence numbers and keeps other keys independent", function()
	local runtime = ready()
	runtime.limits.maxSequence = 2

	local view = TestUtils.baseline(fixture)
	Hints.Send("Game.Look", view, { value = 1 })
	flush()
	Hints.Send("Game.Look", view, { value = 2 })
	flush()
	local accepted, reason = Hints.Send("Game.Look", view, { value = 3 })
	expect(accepted).toBe(false)
	expect(reason).toBe("HintSequenceExhausted")
	local other = TestUtils.baseline(fixture, 8, "ActorB")
	expect((Hints.Send("Game.Look", other, { value = 4 }))).toBe(true)
	flush()
	expect(records()[3].sequence).toBe(1)
end)

it("forgets retired views, drops their unsent data and releases live-key capacity", function()
	local runtime = ready()
	local view = TestUtils.baseline(fixture)
	Hints.Send("Game.Look", view, { value = 1 })
	expect(runtime.latestCount).toBe(1)
	TestUtils.records(fixture, { { kind = "ActorRemove", handle = 7 } })
	expect(runtime.latestCount).toBe(0)
	local accepted, reason = Hints.Send("Game.Look", view, { value = 2 })
	expect(accepted).toBe(false)
	expect(reason).toBe("ActorViewUnavailable")
	flush()
	expect(sent).toEqual({})
	expect(runtime.pendingBytes).toBe(0)
end)

it("drops transport failures without retry, resync or command uncertainty and keeps later sends usable", function()
	local runtime = ready()
	local send = runtime.dependencies.SendUnreliable

	runtime.dependencies.SendUnreliable = function(): ()
		error("UnreliableFailure")
	end

	Hints.Send("Game.Pulse", nil, 1)
	flush()
	expect(runtime.pendingBytes).toBe(0)
	runtime.dependencies.SendUnreliable = send
	Hints.Send("Game.Pulse", nil, 2)
	flush()
	expect(records()).toEqual({ { hintCode = 1, payload = 2 } })
	expect(fixture.sent).toEqual({})
end)

it("cancels pending work and disconnects its pump exactly once on client teardown", function()
	local runtime = ready()
	Hints.Send("Game.Pulse", nil, 1)
	Client._ResetForTests()
	Client._ResetForTests()
	flush()
	expect(sent).toEqual({})
	expect(runtime.pendingCount).toBe(0)
	expect(runtime.latestCount).toBe(0)
	expect(stopCount).toBe(1)
	local accepted, reason = Hints.Send("Game.Pulse", nil, 2)
	expect(accepted).toBe(false)
	expect(reason).toBe("ClientNotReady")
end)

it("keeps existing Latest data intact when a replacement exceeds byte capacity", function()
	local runtime = ready()
	runtime.limits.maxPendingBytes = 20
	expect((Hints.Send("Game.Large", nil, "small"))).toBe(true)
	local accepted, reason = Hints.Send("Game.Large", nil, string.rep("x", 40))
	expect(accepted).toBe(false)
	expect(reason).toBe("HintPendingFull")
	flush()
	expect(records()[1].payload).toBe("small")
	expect(records()[1].sequence).toBe(1)
	runtime.limits.maxBytes = 1
	accepted, reason = Hints.Send("Game.Pulse", nil, 1)
	expect(accepted).toBe(false)
	expect(reason).toBe("HintRateLimited")
	expect(runtime.pendingBytes).toBe(0)
end)

it("bounds live Latest metadata and releases Actor keys at retirement", function()
	local runtime = ready()
	runtime.limits.maxLatestKeys = 1

	local view = TestUtils.baseline(fixture)
	Hints.Send("Game.Look", view, { value = 1 })
	flush()
	local accepted, reason = Hints.Send("Game.Sample", nil, 2)
	expect(accepted).toBe(false)
	expect(reason).toBe("HintLatestKeysFull")
	TestUtils.records(fixture, { { kind = "ActorRemove", handle = 7 } })
	expect((Hints.Send("Game.Sample", nil, 3))).toBe(true)
	flush()
	expect(records()[2].sequence).toBe(1)
end)

it("limits physical sends and batches without fragmenting large records", function()
	local runtime = ready()
	runtime.limits.maxSends = 1
	Hints.Send("Game.Large", nil, string.rep("x", 800))
	Hints.Send("Game.Pulse", nil, 2)

	-- One record fits the physical envelope; the next sample must wait.
	for value = 3, 40 do
		Hints.Send("Game.Pulse", nil, value)
	end

	flush()
	expect(#sent).toBe(1)
	expect(buffer.len(sent[1]) <= 900).toBe(true)
	expect(runtime.pendingCount > 0).toBe(true)
	flush()
	expect(#sent).toBe(2)
	flush()
	expect(runtime.pendingCount).toBe(0)
	expect(#records()).toBe(40)
end)

it("checks live stream mappings both at admission and before transport", function()
	local runtime = ready()
	local view = TestUtils.baseline(fixture)
	local lookup = runtime.stream.GetByActorId

	runtime.stream.GetByActorId = function()
		return nil
	end

	local accepted, reason = Hints.Send("Game.Look", view, { value = 1 })
	expect(accepted).toBe(false)
	expect(reason).toBe("ActorViewUnavailable")
	runtime.stream.GetByActorId = lookup
	Hints.Send("Game.Look", view, { value = 2 })

	runtime.stream.GetByActorId = function()
		return nil
	end

	flush()
	expect(sent).toEqual({})
	expect(runtime.pendingBytes).toBe(0)
	runtime.stream.GetByActorId = lookup
end)

it("encodes the admitted payload once and never re-encodes it during pumping", function()
	local runtime = ready()
	local encode = runtime.codec.EncodeRecord
	local calls = 0

	runtime.codec.EncodeRecord = function(record)
		calls += 1

		return encode(record)
	end

	Hints.Send("Game.Sample", nil, 5)
	expect(calls).toBe(1)
	flush()
	expect(calls).toBe(1)
	expect(records()[1].payload).toBe(5)
end)

it("drops yielding transport work and holds staged bytes through reentrant teardown", function()
	local runtime = ready()

	runtime.dependencies.SendUnreliable = function()
		coroutine.yield()
	end

	Hints.Send("Game.Pulse", nil, 1)
	flush()
	expect(runtime.pendingBytes).toBe(0)
	local during: number? = nil
	local nested: number? = nil

	runtime.dependencies.SendUnreliable = function()
		Client._ResetForTests()
		during = runtime.pendingBytes
		nested = runtime:Step()
	end

	Hints.Send("Game.Sample", nil, 2)
	local charged = runtime.pendingBytes
	flush()
	expect(during).toBe(charged)
	expect(nested).toBe(0)
	expect(runtime.pendingBytes).toBe(0)
	runtime:Destroy()
	expect(runtime.pendingCount).toBe(0)
	local accepted, reason = runtime:Send("Game.Sample", nil, 3)
	expect(accepted).toBe(false)
	expect(reason).toBe("ClientNotReady")
end)

it("rejects invalid private limits before installing an owner", function()
	local runtime = ready()

	local cases: { Types.ClientHintLimits } = { { maxPending = 0 }, { maxSequence = 4294967296 } }

	for _, limits in cases do
		local completed, reason = pcall(
			RuntimeModule.new,
			assert(fixture.protocol, "Expected installed protocol"),
			runtime.stream,
			runtime.dependencies,
			limits
		)

		expect(completed).toBe(false)
		expect(string.find(tostring(reason), "InvalidHint") ~= nil).toBe(true)
	end
end)

it("forwards Hint buffers through the existing native unreliable endpoint", function()
	local source = Instance.new("BindableEvent")
	local forwarded: buffer? = nil

	local owned: any = {
		reliable = { OnClientEvent = source.Event },
		unreliable = {
			FireServer = function(_self, payload)
				forwarded = payload
			end,
		},
	}

	Transport.Locate = function()
		return owned, nil
	end

	local endpoint = assert(originalDiscover(os.clock() + 1))
	local send = assert(endpoint.SendUnreliable, "Expected native unreliable sender")
	local data = buffer.fromstring("owned Hint buffer")
	send(data)
	expect(forwarded).toBe(data)
	source:Destroy()
end)
