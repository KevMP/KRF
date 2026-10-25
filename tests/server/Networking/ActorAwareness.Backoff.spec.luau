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
local Constants = require(KRF.shared.Networking.utils.CommandConstants)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture
local runtime: Types.ActorAwarenessRuntime
local internal: any
local player: Player
local actor: ActorTypes.Actor
local stream: any
local attempts: number

beforeEach(function()
	fixture = TestUtils.new()
	player = TestUtils.player(fixture)
	actor = TestUtils.actor(fixture, nil)
	runtime = TestUtils.start(fixture)
	internal = runtime
	TestUtils.ready(fixture, player)
	TestUtils.drain(fixture)
	fixture.deliveries = {}
	stream = internal.connections[player].actors[actor]
	local anchor = stream.dependencies.Anchor
	attempts = 0

	-- Capacity refusals now stop at the cheap anchor; count actual retry attempts.
	stream.dependencies.Anchor = function(target: ActorTypes.Actor, recipient: Player): (any, any, any)
		attempts += 1

		return anchor(target, recipient)
	end
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

local function invalidate(): ()
	for value = 11, 16 do
		fixture.publicDomain.value = value
		fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = value } })
	end
end

local function advance(count: number): ()
	for _ = 1, count do
		runtime:Step(32768, 128)
	end
end

it(
	"bounds captures under consecutive invalidation and completes the latest multipart generation after quiet",
	function()
		invalidate()

		for _ = 1, 128 do
			runtime:Step(32768, 128)
			invalidate()
		end

		expect(attempts > 1).toBe(true)
		expect(attempts <= 9).toBe(true)
		expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(0)
		expect(internal.backlog.records).toBe(0)
		advance(64)
		local ends = TestUtils.kind(fixture, player, "BaselineEnd")
		expect(#ends).toBe(1)
		local begins = TestUtils.kind(fixture, player, "BaselineBegin")
		expect(ends[1].generation).toBe(begins[#begins].generation)
		local truth = TestUtils.baseline(fixture, player, assert(runtime:GetHandle(player, actor)))
		expect(truth["Game.Public"].value).toBe(16)
		expect(internal.backlog.records).toBe(0)
		expect(internal.backlog.bytes).toBe(0)

		-- Completing End resets the failure streak: the next discontinuity is eligible immediately.
		local completedAttempts = attempts
		invalidate()
		runtime:Step(32768, 128)
		expect(attempts).toBe(completedAttempts + 1)
	end
)

it("retries aggregate capacity refusal on bounded opportunities and releases refused projection buffers", function()
	internal.backlog.limits.maxBytes = 1
	local captured, reason = runtime:RequestReplacementBaseline(player, assert(runtime:GetHandle(player, actor)))
	expect(captured).toBe(false)
	expect(reason).toBe("ActorBaselineCapacity")
	local retryPumps: { number } = {}

	for pump = 1, 128 do
		local previousAttempts = attempts
		runtime:Step(32768, 128)

		if attempts ~= previousAttempts then
			table.insert(retryPumps, pump)
		end
	end

	expect(retryPumps).toEqual({ 2, 6, 14, 30, 62, 94, 126 })
	expect(attempts <= 9).toBe(true)
	expect(attempts > 1).toBe(true)
	expect(internal.backlog.records).toBe(0)
	expect(internal.backlog.bytes).toBe(0)
	expect(internal.projections.baselines[actor] == nil).toBe(true)
	internal.backlog.limits.maxBytes = 4096
	advance(64)
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(1)
	expect(internal.backlog.records).toBe(0)
	expect(internal.backlog.bytes).toBe(0)
end)

it("keeps healthy Actors and another recipient progressing under a shared one-capture budget", function()
	local quiet: ActorTypes.Actor = TestUtils.actor(fixture, nil)
	local other: Player = TestUtils.player(fixture)
	TestUtils.ready(fixture, other)
	advance(16)
	fixture.deliveries = {}
	fixture.options.workLimits = { captures = 1 }

	for _ = 1, 32 do
		invalidate()
		fixture.publicDomain.callbacks[quiet]({ { id = "Changed", payload = 17 } })
		runtime:Step(32768, 128)
		expect(internal.work.used.captures <= 1).toBe(true)
	end

	for _, recipient in { player, other } do
		local commits = TestUtils.kind(fixture, recipient, "Commit")
		expect(#commits).toBe(32)
	end

	expect(attempts <= 6).toBe(true)
	advance(64)

	for _, recipient in { player, other } do
		expect(#TestUtils.kind(fixture, recipient, "BaselineEnd")).toBe(1)
	end

	expect(fixture.faults).toEqual({})
end)

it("holds a newer result behind delayed, refused and association-replaced multipart recovery", function()
	fixture.options.maxChunkBytes = 1
	invalidate()
	local reservation = assert(runtime:ReserveCommandResult(player, 1))
	local result = buffer.create(1)
	buffer.writeu8(result, 0, Constants.RESULT_KIND)
	expect(reservation.Commit(result)).toBe(true)
	local timeline: { string } = {}
	local send = fixture.dependencies.SendReliable

	fixture.dependencies.SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
		if buffer.readu8(payload, 0) == Constants.RESULT_KIND then
			table.insert(timeline, "Result")

			return true, nil
		end

		local records = assert(fixture.codec.Decode(payload))

		for _, record in records do
			table.insert(timeline, record.kind)
		end

		return send(recipient, payload)
	end

	internal.backlog.limits.maxBytes = 1
	advance(12)
	expect(timeline).toEqual({})
	expect(attempts < 6).toBe(true)
	internal.backlog.limits.maxBytes = 4096

	for _ = 1, 32 do
		runtime:Step(32768, 128)

		if #TestUtils.kind(fixture, player, "BaselineBegin") > 0 then
			break
		end
	end

	expect(timeline).toEqual({ "BaselineBegin" })
	-- Association refresh cancels the obsolete retry delay, but not its causal debt.
	TestUtils.associate(fixture, actor, player)
	advance(64)
	expect(timeline[#timeline - 1]).toBe("BaselineEnd")
	expect(timeline[#timeline]).toBe("Result")
	expect(#TestUtils.kind(fixture, player, "BaselineChunk") > 1).toBe(true)
	expect(fixture.faults).toEqual({})
end)

for _, cancellation: string in { "retire", "disconnect", "association", "fault", "destroy" } do
	it("cancels obsolete delayed recovery on " .. cancellation, function()
		internal.backlog.limits.maxBytes = 1

		local captured = runtime:RequestReplacementBaseline(player, assert(runtime:GetHandle(player, actor)))
		expect(captured).toBe(false)
		advance(12)
		local priorAttempts = attempts

		internal.backlog.limits.maxBytes = 4096

		if cancellation == "retire" then
			runtime:OnActorUnregistering(actor)
		elseif cancellation == "disconnect" then
			TestUtils.close(fixture, player)
			TestUtils.ready(fixture, player)
		elseif cancellation == "association" then
			TestUtils.associate(fixture, actor, player)
		elseif cancellation == "fault" then
			stream:Fault("InjectedRecoveryFault")
		else
			runtime:Destroy()
		end

		advance(64)
		expect(attempts).toBe(priorAttempts + (if cancellation == "association" then 1 else 0))

		expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(
			if cancellation == "association" or cancellation == "disconnect" then 1 else 0
		)

		expect(internal.backlog.records).toBe(0)
		expect(internal.backlog.bytes).toBe(0)
	end)
end

it("does not treat small packet budgets or unavailable Begin slots as failed recovery captures", function()
	invalidate()

	local connection: any = internal.connections[player]
	connection.transferCount = 16
	advance(8)
	expect(attempts).toBe(1)
	expect(#TestUtils.kind(fixture, player, "BaselineBegin")).toBe(0)
	connection.transferCount = 0
	runtime:Step(32768, 128)

	for _ = 1, 8 do
		runtime:Step(20, 128)
	end

	expect(attempts).toBe(1)
	advance(16)
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(1)
	expect(fixture.faults).toEqual({})
end)
