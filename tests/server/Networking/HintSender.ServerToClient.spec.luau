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
local Sender = require(KRF.server.Networking.utils.HintSender)
local Wire = require(KRF.shared.Networking.HintCodec)
local Constants = require(KRF.shared.Networking.utils.HintConstants)
local Awareness = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local base: Awareness.Fixture
local awareness: Types.ActorAwarenessRuntime
local runtime: Sender.Runtime
local limits: Types.HintSendLimits
local protocol: SharedTypes.ClientProtocol
local codec: SharedTypes.HintCodec
local first: Player
local second: Player
local actor: ActorTypes.Actor
local now: number
local send: ((Player, buffer) -> ())?
local sent: { { player: Player, payload: buffer } }

beforeEach(function()
	Registry._RollbackStartup()
	base = Awareness.new()
	first, second = Awareness.player(base), Awareness.player(base)
	actor = Awareness.actor(base, first)
	awareness = Awareness.start(base)

	local catalog = assert(Registry.Prepare({
		{
			id = "Game.Input",
			direction = "ClientToServer",
			target = "None",
			mode = "Pulse",
			payload = Schema.U8,
			authorize = function()
				return true, nil
			end,
			receive = function() end,
		},
		{
			id = "Game.Large",
			direction = "ServerToClient",
			target = "None",
			mode = "Latest",
			payload = Schema.String(800),
		},
		{
			id = "Game.Look",
			direction = "ServerToClient",
			target = "Actor",
			mode = "Latest",
			payload = Schema.Struct({ value = Schema.U8 }),
		},
		{ id = "Game.Pulse", direction = "ServerToClient", target = "None", mode = "Pulse", payload = Schema.U8 },
		{ id = "Game.Sample", direction = "ServerToClient", target = "None", mode = "Latest", payload = Schema.U8 },
	}))

	protocol = assert(Networking.Prepare(base.catalog, nil, catalog)).runtime
	codec = Wire.Compile(protocol, "ServerToClient")
	limits = table.clone(Constants.SEND) :: Types.HintSendLimits
	limits.maxRecords, limits.maxConnectionRecords, limits.maxSends = 2, 1, 2
	now, send, sent = 100, nil, {}

	runtime = Sender.new(protocol, {
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
		SendUnreliable = function(player: Player, payload: buffer): ()
			if send ~= nil then
				send(player, payload)
			else
				table.insert(sent, { player = player, payload = payload })
			end
		end,
	}, limits)

	Awareness.ready(base, first)
	Awareness.ready(base, second)
	Awareness.drain(base)
	base.deliveries = {}
end)

afterEach(function()
	runtime:Destroy()
	Awareness.destroy(base)
	Registry._RollbackStartup()
end)

local function records(index: number): { SharedTypes.HintRecord }
	local cursor = assert(codec.Open(sent[index].payload))
	local decoded: { SharedTypes.HintRecord } = {}

	while cursor.remaining > 0 do
		local record = assert(codec.Read(cursor))
		table.insert(decoded, record)
	end

	return decoded
end

it("sends only to the selected recipient with owned payload and that recipient's Actor handle", function()
	local value = { value = 3 }
	expect((runtime:SendTo(second, "Game.Look", actor, value))).toBe(true)
	value.value = 9
	expect(sent).toEqual({})
	runtime:Step()
	expect(#sent).toBe(1)
	expect(sent[1].player).toBe(second)

	expect(records(1)).toEqual({
		{ hintCode = 2, targetHandle = awareness:GetHandle(second, actor), sequence = 1, payload = { value = 3 } },
	})

	expect(base.deliveries).toEqual({})
end)

it("encodes different handles for the same Actor in independently joined recipients", function()
	Awareness.close(base, first)
	Awareness.close(base, second)
	awareness:OnActorUnregistering(actor)
	base.publication:DetachActor(actor)
	local padding = Awareness.actor(base)
	Awareness.ready(base, first)
	local target = Awareness.actor(base, first)
	awareness:OnActorUnregistering(padding)
	base.publication:DetachActor(padding)
	Awareness.ready(base, second)
	Awareness.drain(base)
	expect(awareness:GetHandle(first, target)).toBe(2)
	expect(awareness:GetHandle(second, target)).toBe(1)
	expect((runtime:SendTo(first, "Game.Look", target, { value = 4 }))).toBe(true)
	expect((runtime:SendTo(second, "Game.Look", target, { value = 5 }))).toBe(true)
	runtime:Step()
	expect(records(1)[1].targetHandle).toBe(2)
	expect(records(2)[1].targetHandle).toBe(1)
	expect(records(1)[1].sequence).toBe(1)
	expect(records(2)[1].sequence).toBe(1)
end)

it("rejects invalid direction, targets, schemas and unready recipients before transport", function()
	local absent = Awareness.player(base)

	local cases: { { player: Player, id: string, actor: ActorTypes.Actor?, reason: string } } = {
		{ player = absent, id = "Game.Pulse", reason = "ClientNotReady" },
		{ player = first, id = "Game.Missing", reason = "UnknownHint" },
		{ player = first, id = "Game.Input", reason = "HintDirectionMismatch" },
		{ player = first, id = "Game.Look", reason = "ActorUnavailable" },
		{ player = first, id = "Game.Pulse", actor = actor, reason = "UnexpectedActorTarget" },
	}

	for _, request in cases do
		local accepted, reason = runtime:SendTo(request.player, request.id, request.actor, 1)
		expect(accepted).toBe(false)
		expect(reason).toBe(request.reason)
	end

	local accepted, reason = runtime:SendTo(first, "Game.Look", actor, { value = 256 })
	expect(accepted).toBe(false)
	expect(type(reason)).toBe("string")
	runtime:Step()
	expect(sent).toEqual({})
	expect(runtime.pendingBytes).toBe(0)
end)

it("coalesces each recipient's Latest independently and preserves Pulse occurrences", function()
	limits.maxConnectionRecords, limits.maxRecords = 8, 16
	runtime:SendTo(first, "Game.Sample", nil, 1)
	runtime:SendTo(first, "Game.Sample", nil, 2)
	runtime:SendTo(second, "Game.Sample", nil, 7)
	runtime:SendTo(first, "Game.Pulse", nil, 3)
	runtime:SendTo(first, "Game.Pulse", nil, 4)
	runtime:Step()

	expect(records(1)).toEqual({
		{ hintCode = 4, sequence = 2, payload = 2 },
		{ hintCode = 3, payload = 3 },
		{ hintCode = 3, payload = 4 },
	})

	expect(records(2)).toEqual({ { hintCode = 4, sequence = 1, payload = 7 } })
	expect(runtime.pendingCount).toBe(0)
end)

it("gives another eligible recipient a turn within global work and send bounds", function()
	for value = 1, 5 do
		runtime:SendTo(first, "Game.Pulse", nil, value)
	end

	runtime:SendTo(second, "Game.Pulse", nil, 9)
	local work, sends = runtime:Step()
	expect(work).toBe(2)
	expect(sends).toBe(2)
	expect(sent[1].player).toBe(first)
	expect(sent[2].player).toBe(second)
	expect(runtime.pendingCount).toBe(4)
end)

it("bounds local and aggregate pending jobs and recovers capacity on disconnect", function()
	limits.maxPending, limits.maxGlobalPending = 2, 3
	runtime:SendTo(first, "Game.Pulse", nil, 1)
	runtime:SendTo(first, "Game.Pulse", nil, 2)
	local accepted, reason = runtime:SendTo(first, "Game.Pulse", nil, 3)
	expect(accepted).toBe(false)
	expect(reason).toBe("HintPendingFull")
	runtime:SendTo(second, "Game.Pulse", nil, 4)
	accepted, reason = runtime:SendTo(second, "Game.Pulse", nil, 5)
	expect(accepted).toBe(false)
	expect(reason).toBe("HintPendingFull")
	Awareness.close(base, first)
	expect((runtime:SendTo(second, "Game.Pulse", nil, 6))).toBe(true)
	expect(runtime.pendingCount).toBe(2)
end)

it("bounds byte ownership and preserves the prior Latest when a larger replacement cannot fit", function()
	limits.maxPendingBytes = 20
	runtime:SendTo(first, "Game.Large", nil, "small")
	local accepted, reason = runtime:SendTo(first, "Game.Large", nil, string.rep("x", 40))
	expect(accepted).toBe(false)
	expect(reason).toBe("HintPendingFull")
	runtime:Step()
	expect(records(1)[1].payload).toBe("small")
	limits.maxGlobalPendingBytes = 2
	accepted, reason = runtime:SendTo(second, "Game.Pulse", nil, 1)
	expect(accepted).toBe(false)
	expect(reason).toBe("HintPendingFull")
end)

it("bounds aggregate and per-recipient attempts and admitted bytes with window recovery", function()
	limits.maxAttempts, limits.maxGlobalAttempts = 1, 2
	expect((runtime:SendTo(first, "Game.Pulse", nil, 1))).toBe(true)
	local accepted, reason = runtime:SendTo(first, "Game.Pulse", nil, 2)
	expect(accepted).toBe(false)
	expect(reason).toBe("HintRateLimited")
	expect((runtime:SendTo(second, "Game.Pulse", nil, 3))).toBe(true)
	local third = Awareness.player(base)
	Awareness.ready(base, third)
	expect((runtime:SendTo(third, "Game.Pulse", nil, 4))).toBe(false)
	now += 1
	limits.maxBytes = 2
	accepted, reason = runtime:SendTo(first, "Game.Pulse", nil, 5)
	expect(accepted).toBe(false)
	expect(reason).toBe("HintRateLimited")
	now += 1
	limits.maxBytes, limits.maxGlobalBytes = 65536, 2
	expect((runtime:SendTo(third, "Game.Pulse", nil, 6))).toBe(false)
	now += 1
	limits.maxGlobalBytes = 65536
	expect((runtime:SendTo(third, "Game.Pulse", nil, 7))).toBe(true)
end)

it("bounds live sequence keys without evicting prior streams and never wraps", function()
	limits.maxLatestKeys, limits.maxGlobalLatestKeys, limits.maxSequence = 1, 1, 2
	runtime:SendTo(first, "Game.Sample", nil, 1)
	local accepted, reason = runtime:SendTo(first, "Game.Look", actor, { value = 2 })
	expect(accepted).toBe(false)
	expect(reason).toBe("HintLatestKeysFull")
	expect((runtime:SendTo(second, "Game.Sample", nil, 3))).toBe(false)
	runtime:Step()
	runtime:SendTo(first, "Game.Sample", nil, 2)
	runtime:Step()
	accepted, reason = runtime:SendTo(first, "Game.Sample", nil, 3)
	expect(accepted).toBe(false)
	expect(reason).toBe("HintSequenceExhausted")
	Awareness.close(base, first)
	expect((runtime:SendTo(second, "Game.Sample", nil, 4))).toBe(true)
	runtime:Step()
	expect(records(3)[1].sequence).toBe(1)
end)

it("drops retired Actor work, releases its keys and refuses obsolete targets without recovery", function()
	runtime:SendTo(first, "Game.Look", actor, { value = 1 })
	expect(runtime.latestCount).toBe(1)
	awareness:OnActorUnregistering(actor)
	expect(runtime.pendingCount).toBe(0)
	expect(runtime.latestCount).toBe(0)
	local accepted, reason = runtime:SendTo(first, "Game.Look", actor, { value = 2 })
	expect(accepted).toBe(false)
	expect(reason).toBe("ActorUnavailable")
	runtime:Step()
	expect(sent).toEqual({})
end)

it("keeps complete packet bytes within pump limits without fragmenting records", function()
	limits.maxConnectionRecords, limits.maxRecords, limits.maxSends, limits.maxStepBytes = 32, 32, 4, 900
	runtime:SendTo(first, "Game.Large", nil, string.rep("x", 800))

	for value = 1, 40 do
		runtime:SendTo(first, "Game.Pulse", nil, value)
	end

	runtime:Step()
	expect(#sent).toBe(1)
	expect(buffer.len(sent[1].payload) <= 900).toBe(true)
	expect(runtime.pendingCount > 0).toBe(true)

	for _ = 1, 4 do
		runtime:Step()
	end

	expect(runtime.pendingCount).toBe(0)

	for _, delivery in sent do
		expect(buffer.len(delivery.payload) <= 900).toBe(true)
	end
end)

it("drops throwing and yielding transport calls without retrying or blocking healthy recipients", function()
	send = function(player: Player, payload: buffer): ()
		if player == first then
			error("UnreliableFailure")
		end

		table.insert(sent, { player = player, payload = payload })
	end

	runtime:SendTo(first, "Game.Pulse", nil, 1)
	runtime:SendTo(second, "Game.Pulse", nil, 2)
	runtime:Step()
	expect(#sent).toBe(1)
	expect(sent[1].player).toBe(second)

	send = function(): ()
		coroutine.yield()
	end

	runtime:SendTo(first, "Game.Pulse", nil, 3)
	runtime:Step()
	expect(runtime.pendingBytes).toBe(0)
	expect((runtime:Step())).toBe(0)
end)

it("holds staged capacity through reentrant teardown and releases it exactly once", function()
	local during: number? = nil
	local nested: number? = nil

	send = function(): ()
		runtime:Destroy()
		during = runtime.pendingBytes
		nested = runtime:Step()
	end

	runtime:SendTo(first, "Game.Pulse", nil, 1)
	runtime:SendTo(second, "Game.Pulse", nil, 2)
	runtime:Step()
	expect(during).toBe(3)
	expect(nested).toBe(0)
	expect(runtime.pendingCount).toBe(0)
	expect(runtime.pendingBytes).toBe(0)
	runtime:Destroy()
	expect(runtime.pendingBytes).toBe(0)
end)
