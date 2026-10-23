--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local Constants = require(KRF.shared.Networking.utils.CommandConstants)
local Timer = require(KRF.shared.Networking.utils.CommandTimer)
local TestUtils = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)
local AwarenessUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local Clock = require(script.Parent.Parent.Parent.shared.Utils.TestClock)
local fixture: TestUtils.Fixture? = nil
local originalSchedule: typeof(Timer.Schedule) = Timer.Schedule

afterEach(function()
	TestUtils.destroy(fixture)
	fixture = nil
	Timer.Schedule = originalSchedule
end)

local function command(publish: boolean?): Types.CommandDefinition
	return {
		id = "Game.Command",
		target = "None",
		authorize = function(): (boolean, string?)
			return true, nil
		end,
		handle = function(): Types.CommandHandlerResult
			if publish then
				local current: TestUtils.Fixture = fixture :: TestUtils.Fixture
				current.base.publicDomain.value = 11
				current.base.publicDomain.callbacks[current.actor]({ { id = "Changed", payload = 11 } })
			end

			return { accepted = true }
		end,
	}
end

it(
	"rejects reservations for unready/destroyed connections and active or invalid reservations without stranding the queue",
	function()
		local created: TestUtils.Fixture = TestUtils.new({ command() })
		fixture = created
		local unknown: Player = AwarenessUtils.player(created.base)
		local token: Types.CommandReservation?, reason: string? = created.awareness:ReserveCommandResult(unknown, 10)
		expect(token).toBeNil()
		expect(reason).toBe("ClientNotReady")
		token, reason = created.awareness:ReserveCommandResult(created.player, 0)
		expect(token).toBeNil()
		expect(reason).toBe("InvalidCommandReservation")
		token = created.awareness:ReserveCommandResult(created.player, 10)
		assert(token ~= nil, "Expected bounded private reservation")
		expect((created.awareness:ReserveCommandResult(created.player, 10))).toBeNil()
		token.Cancel()
		created.awareness:Step(100, 1)
		created.awareness:Destroy()
		expect((created.awareness:ReserveCommandResult(created.player, 10))).toBeNil()
	end
)

for _, callback: boolean in { false, true } do
	it(
		"expires a blocked result and releases connection-local publication fences with close observer "
			.. tostring(callback),
		function()
			local clock = Clock.new(100)

			Timer.Schedule = clock.Schedule

			local created: TestUtils.Fixture = TestUtils.new({ command(true) })
			fixture = created
			local closed: number = 0

			if callback then
				created.base.dependencies.CloseConnection = function(player: Player, reason: string): ()
					expect(reason).toBe("CommandOutputExpired")
					closed += 1
					AwarenessUtils.close(created.base, player)
				end
			end

			TestUtils.send(created, 1)
			created.now = 131
			clock.Advance(31)
			expect(closed).toBe(if callback then 1 else 0)
			expect(created.awareness:GetHandle(created.player, created.actor)).toBeNil()
			expect(created.awareness:GetHandle(created.other, created.actor)).never.toBeNil()
			created.runtime:Destroy()
			expect(clock.Count()).toBe(0)
		end
	)
end

for _, failure: string in { "False", "Throw" } do
	it("releases all requester output after Reliable send " .. failure .. " while other recipients continue", function()
		local created: TestUtils.Fixture = TestUtils.new({ command(true) })
		fixture = created
		local send: typeof(created.base.dependencies.SendReliable) = created.base.dependencies.SendReliable

		created.base.dependencies.SendReliable = function(player: Player, payload: buffer): (boolean, string?)
			if player == created.player and buffer.readu8(payload, 0) == Constants.RESULT_KIND then
				if failure == "Throw" then
					error("ResultSendFailure")
				end

				return false, "ResultSendFailure"
			end

			return send(player, payload)
		end

		created.base.dependencies.CloseConnection = function(player: Player, reason: string): ()
			expect(reason).toBe("CommandResultSendFailed")
			AwarenessUtils.close(created.base, player)
		end

		TestUtils.send(created, 1)
		AwarenessUtils.drain(created.base)
		expect(created.awareness:GetHandle(created.player, created.actor)).toBeNil()
		TestUtils.send(created, 1, nil, nil, nil, created.other)
		expect(TestUtils.results(created, created.other)[1].status).toBe("Accepted")
	end)
end

it("honors small step budgets without losing a result or releasing its later Actor work first", function()
	local created: TestUtils.Fixture = TestUtils.new({ command(true) })
	fixture = created
	TestUtils.send(created, 1)
	created.awareness:Step(1, 1)
	expect(created.base.deliveries).toEqual({})
	created.awareness:Step(1000, 1)
	local first = created.base.deliveries[1]
	expect(first.player).toBe(created.player)
	expect(buffer.readu8(first.payload, 0)).toBe(Constants.RESULT_KIND)
	AwarenessUtils.drain(created.base)
	expect(#TestUtils.results(created)).toBe(1)
end)

it("releases a fenced replacement baseline after the result when the Actor queue reaches its event bound", function()
	local created: TestUtils.Fixture = TestUtils.new({ command() })
	fixture = created
	local scope: Types.CommandReservation? = created.awareness:ReserveCommandResult(created.player, 100)
	assert(scope ~= nil, "Expected reservation")

	for value: number = 11, 16 do
		created.base.publicDomain.value = value
		created.base.publicDomain.callbacks[created.actor]({ { id = "Changed", payload = value } })
	end

	local result: buffer? = created.codec.EncodeResult({ commandCode = 0, requestId = 1, status = "Accepted" })
	assert(result ~= nil, "Expected real result envelope")
	expect(scope.Commit(result)).toBe(true)
	AwarenessUtils.drain(created.base)
	local first: buffer? = nil

	for _, delivery in created.base.deliveries do
		if delivery.player == created.player then
			first = delivery.payload
			break
		end
	end

	assert(first ~= nil, "Expected bounded requester output")
	expect(buffer.readu8(first, 0)).toBe(Constants.RESULT_KIND)
	expect(created.base.faults).toEqual({})
end)
