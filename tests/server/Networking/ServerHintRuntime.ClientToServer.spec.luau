--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local ActorTypes = require(KRF.server.Actor.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Registry = require(KRF.server.Networking.HintRegistry)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Module = require(KRF.server.Networking.ServerHintRuntime)
local Authorization = require(KRF.server.Networking.HintAuthorization)
local Wire = require(KRF.shared.Networking.HintCodec)
local Awareness = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local base: Awareness.Fixture
local runtime: any
local internal: any
local awareness: Types.ActorAwarenessRuntime
local codec: SharedTypes.HintCodec
local player: Player
local other: Player
local actor: ActorTypes.Actor
local received: { { context: Types.HintContext, payload: any } }
local now: number
local allowed: boolean
local callback: (() -> ())?
local authorizeCallback: (() -> ())?

beforeEach(function()
	Registry._RollbackStartup()
	base = Awareness.new()
	player, other = Awareness.player(base), Awareness.player(base)
	actor = Awareness.actor(base, player)
	awareness = Awareness.start(base)
	received, now, allowed, callback = {}, 100, true, nil
	authorizeCallback = nil

	local function receive(context: Types.HintContext, payload: any): ()
		table.insert(received, { context = context, payload = payload })

		if callback ~= nil then
			callback()
		end
	end

	local catalog = assert(Registry.Prepare({
		{
			id = "Game.Look",
			direction = "ClientToServer",
			target = "Actor",
			mode = "Latest",
			payload = Schema.Struct({ value = Schema.U8 }),
			authorize = function(context: Types.HintContext): (boolean, string?)
				if authorizeCallback ~= nil then
					authorizeCallback()
				end

				return allowed and Authorization.OwnerActor(context, nil), nil
			end,
			receive = receive,
		},
		{
			id = "Game.Pulse",
			direction = "ClientToServer",
			target = "None",
			mode = "Pulse",
			payload = Schema.U8,
			authorize = function(context: Types.HintContext): (boolean, string?)
				if authorizeCallback ~= nil then
					authorizeCallback()
				end

				return allowed and Authorization.AnyReadyClient(context, nil), nil
			end,
			receive = receive,
		},
	}))

	local protocol = assert(Networking.Prepare(base.catalog, nil, catalog))
	codec = Wire.Compile(protocol.runtime)

	runtime = Module.new(catalog, protocol.runtime, {
		Now = function(): number
			return now
		end,
		IsClientReady = base.dependencies.IsClientReady,
		ObserveClientReady = base.dependencies.ObserveClientReady,
		ObserveClientClosed = base.dependencies.ObserveClientClosed,
		ObserveActorRemoved = function(observer)
			return awareness:ObserveActorRemoved(observer)
		end,
		awareness = awareness,
	}, {
		maxRecords = 2,
		maxPendingPackets = 2,
		maxGlobalPendingPackets = 4,
		maxPackets = 4,
		maxGlobalPackets = 8,
		maxLatestKeys = 2,
		maxGlobalLatestKeys = 3,
	})

	internal = runtime
	Awareness.ready(base, player)
	Awareness.ready(base, other)
	Awareness.drain(base)
	base.deliveries = {}
end)

afterEach(function()
	runtime:Destroy()
	Awareness.destroy(base)
	Registry._RollbackStartup()
end)

local function packet(value: number, sequence: number?, recipient: Player?): buffer
	local record = assert(codec.EncodeRecord({
		hintCode = if sequence ~= nil then 0 else 1,
		targetHandle = if sequence ~= nil then awareness:GetHandle(recipient or player, actor) else nil,
		sequence = sequence,
		payload = if sequence ~= nil then { value = value } else value,
	}))

	local encoded = assert(codec.Pack({ record }))

	return encoded
end

it("charges each decoded record and retains a partial packet across bounded dispatch pumps", function()
	local records: { buffer } = {}

	for value = 1, 3 do
		local record = assert(codec.EncodeRecord({ hintCode = 1, payload = value }))
		table.insert(records, record)
	end

	local data = assert(codec.Pack(records))
	expect((runtime:Handle(player, data))).toBe(true)
	local work, delivered = runtime:Step()
	expect(work).toBe(2)
	expect(delivered).toBe(2)
	expect(#received).toBe(2)
	expect(internal.pendingCount).toBe(1)
	expect(internal.pendingBytes).toBe(buffer.len(data))
	work, delivered = runtime:Step()
	expect(work).toBe(1)
	expect(delivered).toBe(1)
	expect(received[3].payload).toBe(3)
	expect(internal.pendingBytes).toBe(0)
	expect((runtime:Step())).toBe(0)
end)

it("queues bounded wire ownership and dispatches only schema-owned immutable semantic data", function()
	expect((runtime:Handle(player, packet(9, 1)))).toBe(true)
	expect(received).toEqual({})
	local work, delivered = runtime:Step()
	expect(work).toBe(1)
	expect(delivered).toBe(1)

	expect(received).toEqual({
		{ context = { player = player, actor = actor, hintId = "Game.Look" }, payload = { value = 9 } },
	})

	expect(table.isfrozen(received[1].context)).toBe(true)
	expect(table.isfrozen(received[1].payload)).toBe(true)
	expect(base.deliveries).toEqual({})
	expect(internal.pendingBytes).toBe(0)
end)

it("suppresses stale Latest samples independently per definition, Actor and active connection", function()
	runtime:Handle(player, packet(5, 5))
	runtime:Step()
	runtime:Handle(player, packet(2, 2))
	runtime:Handle(player, packet(5, 5))
	runtime:Step()
	expect(#received).toBe(1)
	runtime:Handle(player, packet(7, 6))
	runtime:Step()
	expect(received[2].payload.value).toBe(7)
end)

it("does not confuse awareness with authorization or deliver denied payloads", function()
	runtime:Handle(other, packet(7, 1, other))
	runtime:Step()
	allowed = false
	runtime:Handle(player, packet(7, 1))
	runtime:Step()
	expect(received).toEqual({})
	expect(internal.latestCount).toBe(0)
	allowed = true
	runtime:Handle(player, packet(8, 1))
	runtime:Step()
	expect(#received).toBe(1)
end)

it("bounds aggregate wire queues, gives another connection a turn and recovers capacity", function()
	runtime:Handle(player, packet(1))
	runtime:Handle(player, packet(2))
	local admitted, reason = runtime:Handle(player, packet(3))
	expect(admitted).toBe(false)
	expect(reason).toBe("HintPendingFull")
	expect((runtime:Handle(other, packet(4)))).toBe(true)
	local work = runtime:Step()
	expect(work).toBe(2)
	expect(received[1].context.player).toBe(player)
	expect(received[2].context.player).toBe(other)
	runtime:Step()
	expect(internal.pendingCount).toBe(0)
	expect(internal.pendingBytes).toBe(0)
end)

it("bounds malformed and valid admission attempts before decoding and resets rate windows", function()
	for _ = 1, 4 do
		runtime:Handle(player, false)
	end

	local admitted, reason = runtime:Handle(player, packet(1))
	expect(admitted).toBe(false)
	expect(reason).toBe("HintRateLimited")
	expect((runtime:Handle(other, packet(2)))).toBe(true)
	runtime:Step()
	now += 1
	expect((runtime:Handle(player, packet(3)))).toBe(true)
	runtime:Step()
	expect(#received).toBe(2)
end)

it("drops malformed framing and extra arguments without invoking callbacks or reliable recovery", function()
	local admitted, reason = runtime:Handle(player, packet(1), true)
	expect(admitted).toBe(false)
	expect(reason).toBe("MalformedHintPacket")
	local data = packet(1, 1)
	buffer.writeu16(data, 9, 255)
	runtime:Handle(player, data)
	runtime:Step()
	expect(received).toEqual({})
	expect(base.deliveries).toEqual({})
end)

it("isolates throwing and yielding consumers without stopping later delivery", function()
	callback = function(): ()
		coroutine.yield()
	end

	runtime:Handle(player, packet(1))
	runtime:Step()

	callback = function(): ()
		error("CosmeticFailure")
	end

	runtime:Handle(player, packet(2))
	runtime:Step()
	callback = nil
	runtime:Handle(player, packet(3))
	runtime:Step()
	expect(#received).toBe(3)
	expect(internal.pendingBytes).toBe(0)
end)

it("holds selected wire capacity through reentrant close and releases it exactly once after dispatch", function()
	local during: number? = nil
	local nestedWork: number? = nil

	callback = function(): ()
		Awareness.close(base, player)
		during = internal.pendingBytes
		nestedWork = runtime:Step()
	end

	local data = packet(1)
	runtime:Handle(player, data)
	runtime:Step()
	expect(during).toBe(buffer.len(data))
	expect(nestedWork).toBe(0)
	expect(internal.pendingBytes).toBe(0)
	runtime:Destroy()
	expect(internal.pendingBytes).toBe(0)
end)

it("removes retired-Actor sequence state and rejects obsolete handles without resync", function()
	local stale = packet(1, 1)
	runtime:Handle(player, stale)
	runtime:Step()
	expect(internal.latestCount).toBe(1)
	awareness:OnActorUnregistering(actor)
	expect(internal.latestCount).toBe(0)
	runtime:Handle(player, stale)
	runtime:Step()
	expect(#received).toBe(1)
end)

it("denies forged and expired authorization contexts", function()
	local forged: Types.HintContext = { player = player, actor = actor, hintId = "Game.Look" }
	local allowedOwner, ownerReason = Authorization.OwnerActor(forged, nil)
	expect(allowedOwner).toBe(false)
	expect(ownerReason).toBe("ActorNotOwned")
	local allowedReady, readyReason = Authorization.AnyReadyClient(forged, nil)
	expect(allowedReady).toBe(false)
	expect(readyReason).toBe("ClientNotReady")
	runtime:Handle(player, packet(1, 1))
	runtime:Step()
	expect(#received).toBe(1)
	expect((Authorization.OwnerActor(received[1].context, nil))).toBe(false)
	expect((Authorization.AnyReadyClient(received[1].context, nil))).toBe(false)
end)

it("isolates failing authorization and rechecks connection lifetime before receive", function()
	authorizeCallback = function(): ()
		coroutine.yield()
	end

	runtime:Handle(player, packet(1, 1))
	runtime:Step()

	authorizeCallback = function(): ()
		error("AuthorizationFailure")
	end

	runtime:Handle(player, packet(2, 1))
	runtime:Step()
	expect(received).toEqual({})
	expect(internal.latestCount).toBe(0)

	authorizeCallback = function(): ()
		Awareness.close(base, player)
	end

	runtime:Handle(player, packet(3, 1))
	runtime:Step()
	expect(received).toEqual({})
	expect(internal.pendingBytes).toBe(0)
end)

it("releases aggregate queue capacity when a saturated connection disconnects", function()
	local third = Awareness.player(base)
	Awareness.ready(base, third)

	for _, recipient in { player, other } do
		for value = 1, 2 do
			expect((runtime:Handle(recipient, packet(value)))).toBe(true)
		end
	end

	local admitted, reason = runtime:Handle(third, packet(3))
	expect(admitted).toBe(false)
	expect(reason).toBe("HintPendingFull")
	Awareness.close(base, player)
	expect((runtime:Handle(third, packet(4)))).toBe(true)
	runtime:Step()
	expect(received[2].context.player).toBe(third)
end)

it("bounds aggregate malformed attempts and restores admission after the window", function()
	for _, recipient in { player, other } do
		for _ = 1, 4 do
			runtime:Handle(recipient, false)
		end
	end

	local third = Awareness.player(base)
	Awareness.ready(base, third)
	local admitted, reason = runtime:Handle(third, packet(1))
	expect(admitted).toBe(false)
	expect(reason).toBe("HintRateLimited")
	now += 1
	expect((runtime:Handle(third, packet(2)))).toBe(true)
	runtime:Step()
	expect(#received).toBe(1)
end)

it("enforces local and aggregate byte ceilings without retaining refused packets", function()
	local data = packet(1)

	for _, limit in { "maxBytes", "maxGlobalBytes", "maxPendingBytes", "maxGlobalPendingBytes" } do
		internal.limits[limit] = buffer.len(data) - 1
		local admitted, reason = runtime:Handle(player, data)
		expect(admitted).toBe(false)
		expect(reason).toBe(if string.find(limit, "Pending") then "HintPendingFull" else "HintRateLimited")
		expect(internal.pendingBytes).toBe(0)
		internal.limits[limit] = 65536
	end
end)

it("caps Latest keys globally and recovers them on disconnect", function()
	internal.limits.maxGlobalLatestKeys = 1
	runtime:Handle(player, packet(1, 1))
	runtime:Step()
	local otherActor = Awareness.actor(base, other)
	Awareness.drain(base)

	local record = assert(codec.EncodeRecord({
		hintCode = 0,
		targetHandle = awareness:GetHandle(other, otherActor),
		sequence = 1,
		payload = { value = 2 },
	}))

	local data = assert(codec.Pack({ record }))
	runtime:Handle(other, data)
	runtime:Step()
	expect(#received).toBe(1)
	Awareness.close(base, player)
	runtime:Handle(other, data)
	runtime:Step()
	expect(#received).toBe(2)
	expect(internal.latestCount).toBe(1)
end)

it("keeps selected bytes charged through reentrant runtime destruction", function()
	local during: number? = nil

	callback = function(): ()
		runtime:Destroy()
		during = internal.pendingBytes
	end

	local data = packet(1)
	runtime:Handle(player, data)
	runtime:Handle(other, packet(2))
	runtime:Step()
	expect(during).toBe(buffer.len(data))
	expect(internal.pendingCount).toBe(0)
	expect(internal.pendingBytes).toBe(0)
	runtime:Destroy()
	expect(internal.pendingBytes).toBe(0)
end)

it("clears closed connection state, refuses old Players and cancels queued work on teardown", function()
	runtime:Handle(player, packet(1, 1))
	runtime:Step()
	runtime:Handle(player, packet(2))
	Awareness.close(base, player)
	expect(internal.latestCount).toBe(0)
	expect(internal.pendingCount).toBe(0)
	local admitted, reason = runtime:Handle(player, packet(3))
	expect(admitted).toBe(false)
	expect(reason).toBe("ClientNotReady")
	runtime:Handle(other, packet(4))
	runtime:Destroy()
	runtime:Step()
	expect(#received).toBe(1)
	expect(internal.pendingBytes).toBe(0)
end)
