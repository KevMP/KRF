--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Authorization = require(KRF.server.Networking.CommandAuthorization)
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

local function definition(handle: Types.CommandHandler): Types.CommandDefinition
	return { id = "Game.Command", target = "None", authorize = Authorization.AnyReadyClient, handle = handle }
end

it("binds authorization helpers only to the actual active invocation and releases escaped contexts", function()
	local escaped: Types.CommandContext? = nil

	local command: Types.CommandDefinition = definition(
		function(context: Types.CommandContext): Types.CommandHandlerResult
			escaped = context
			expect((Authorization.AnyReadyClient(context, nil))).toBe(true)
			expect((Authorization.OwnerActor(context, nil))).toBe(true)

			return { accepted = true }
		end
	)

	command.target = "Actor"

	local created: TestUtils.Fixture = TestUtils.new({ command })
	fixture = created
	TestUtils.send(created, 1, nil, created.actor)
	assert(escaped ~= nil, "Expected production-bound context")
	local retained: Types.CommandContext = escaped :: Types.CommandContext
	local allowed: boolean, reason: string? = Authorization.AnyReadyClient(retained, nil)
	expect(allowed).toBe(false)
	expect(reason).toBe("ClientNotReady")
	expect((Authorization.OwnerActor(retained, nil))).toBe(false)
	expect((Authorization.AnyReadyClient({} :: any, nil))).toBe(false)
	expect(retained:GetPriorOutcome(1)).toBeNil()
	expect(created.faults).toEqual({})
end)

it("expires quiescent history with an owned timer and cancels every timer on repeated destruction", function()
	local clock = Clock.new(100)

	Timer.Schedule = clock.Schedule

	local created: TestUtils.Fixture = TestUtils.new({
		definition(function(context: Types.CommandContext): Types.CommandHandlerResult
			if context.requestId == 2 then
				expect(context:GetPriorOutcome(1)).toBeNil()
			end

			return { accepted = true }
		end),
	})

	fixture = created
	TestUtils.send(created, 1)
	TestUtils.results(created)
	expect(clock.Count()).toBe(1)
	created.now = 131
	clock.Advance(31)
	expect(clock.Count()).toBe(0)
	TestUtils.send(created, 2)
	created.runtime:Destroy()
	created.runtime:Destroy()
	AwarenessUtils.close(created.base, created.player)
	expect(created.faults).toEqual({})
end)

for _, operation: string in { "Disconnect", "Destroy", "NotReady" } do
	it("does not retain or publish a late outcome when " .. operation .. " occurs inside the handler", function()
		local created: TestUtils.Fixture = TestUtils.new({
			definition(function(): Types.CommandHandlerResult
				local current: TestUtils.Fixture = fixture :: TestUtils.Fixture

				if operation == "Disconnect" then
					AwarenessUtils.close(current.base, current.player)
				elseif operation == "Destroy" then
					current.runtime:Destroy()
				else
					current.base.readyPlayers[current.player] = nil
				end

				return { accepted = true }
			end),
		})

		fixture = created
		TestUtils.send(created, 1)
		expect(TestUtils.results(created)).toEqual({})
		expect(created.faults).toEqual({})
	end)
end

it("revalidates a formerly valid target before entering author callbacks", function()
	local calls: number = 0

	local command: Types.CommandDefinition = definition(function(): Types.CommandHandlerResult
		calls += 1

		return { accepted = true }
	end)

	command.target = "Actor"

	local created: TestUtils.Fixture = TestUtils.new({ command })
	fixture = created
	local request: buffer = TestUtils.request(created, 1, nil, nil, created.actor, nil)
	created.awareness:OnActorUnregistering(created.actor)
	created.runtime:Handle(created.player, request)
	local results: { SharedTypes.CommandResult } = TestUtils.results(created)
	expect(calls).toBe(0)
	expect(results[1].status).toBe("Rejected")
	expect(results[1].reason).toBe("ActorUnavailable")
end)

it("charges rate bytes independently and resets the window without reusing consumed ids", function()
	local calls: number = 0

	local created: TestUtils.Fixture = TestUtils.new(
		{ definition(function(): Types.CommandHandlerResult
			calls += 1

			return { accepted = true }
		end) },
		{ maxBytes = 11 }
	)

	fixture = created
	TestUtils.send(created, 1)
	local admitted: boolean, reason: string? = TestUtils.send(created, 2)
	expect(admitted).toBe(false)
	expect(reason).toBe("CommandRateLimited")
	created.now += 2
	TestUtils.send(created, 3)
	expect(calls).toBe(2)
end)

it("limits queued bytes during reentry before another callback runs", function()
	local calls: number = 0

	local created: TestUtils.Fixture = TestUtils.new({
		definition(function(context: Types.CommandContext): Types.CommandHandlerResult
			calls += 1

			if context.requestId == 1 then
				local current: TestUtils.Fixture = fixture :: TestUtils.Fixture
				TestUtils.send(current, 2)
				local admitted: boolean, reason: string? = TestUtils.send(current, 3)
				expect(admitted).toBe(false)
				expect(reason).toBe("CommandQueueFull")
			end

			return { accepted = true }
		end),
	}, { maxQueuedBytes = 11 })

	fixture = created
	TestUtils.send(created, 1)
	expect(calls).toBe(2)
	expect(created.faults).toEqual({})
end)

it("cleans up when fault reporting closes the connection instead of restoring history or output", function()
	local created: TestUtils.Fixture =
		TestUtils.new({ definition(function(): Types.CommandHandlerResult
			error("HandlerFault")
		end) })

	fixture = created

	created.dependencies.ReportFault = function(player: Player, _fault: string): ()
		AwarenessUtils.close(created.base, player)
	end

	TestUtils.send(created, 1)
	expect(TestUtils.results(created)).toEqual({})
end)

it("closes a connection whose reserved result cannot be committed after execution", function()
	local created: TestUtils.Fixture =
		TestUtils.new({ definition(function(): Types.CommandHandlerResult
			return { accepted = true }
		end) })

	fixture = created

	created.awareness.ReserveCommandResult = function(): (Types.CommandReservation?, string?)
		return {
			Commit = function(_payload: buffer): boolean
				return false
			end,
			Cancel = function(): () end,
		},
			nil
	end

	TestUtils.send(created, 1)
	expect(created.closed).toEqual({ created.player })
	expect(TestUtils.results(created)).toEqual({})
end)

it("contains a reservation failure and closes its connection without entering gameplay", function()
	local calls: number = 0

	local created: TestUtils.Fixture = TestUtils.new({
		definition(function(): Types.CommandHandlerResult
			calls += 1

			return { accepted = true }
		end),
	})

	fixture = created

	created.awareness.ReserveCommandResult = function(): (Types.CommandReservation?, string?)
		error("ReservationFault")
	end

	TestUtils.send(created, 1)
	expect(calls).toBe(0)
	expect(created.faults).toEqual({ "CommandInternalFault" })
	expect(created.closed).toEqual({ created.player })
end)
