--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local TestUtils = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)
local AwarenessUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture? = nil

afterEach(function()
	TestUtils.destroy(fixture)
	fixture = nil
end)

local function definition(handler: Types.CommandHandler): Types.CommandDefinition
	return {
		id = "Game.Command",
		target = "None",
		result = Schema.Struct({ sequenceId = Schema.U32 }),
		authorize = function(): (boolean, string?)
			return true, nil
		end,
		handle = handler,
	}
end

for _, fault: string in
	{ "Throw", "Yield", "Malformed", "InvalidResult", "RejectedWithResult", "UnboundedReason", "ExtraField" }
do
	it(
		"retains Unknown after handler " .. fault .. " and preserves committed effects without a false rejection",
		function()
			local effects: number = 0
			local previous: Types.CommandOutcome? = nil

			local created: TestUtils.Fixture = TestUtils.new({
				definition(function(context: Types.CommandContext): Types.CommandHandlerResult
					if context.requestId == 2 then
						previous = context:GetPriorOutcome(1)

						return { accepted = false, reason = "PriorUncertain" }
					end

					effects += 1

					if fault == "Throw" then
						error("AfterEffect")
					end

					if fault == "Yield" then
						coroutine.yield()
					end

					if fault == "Malformed" then
						return nil :: any
					end

					if fault == "InvalidResult" then
						return { accepted = true, result = { sequenceId = -1 } }
					end

					if fault == "RejectedWithResult" then
						return { accepted = false, reason = "Denied", result = { sequenceId = 4 } }
					end

					if fault == "UnboundedReason" then
						return { accepted = false, reason = string.rep("x", 65) }
					end

					return { accepted = true, result = { sequenceId = 4 }, secret = true } :: any
				end),
			})

			fixture = created
			TestUtils.send(created, 1)
			TestUtils.send(created, 2)
			expect(effects).toBe(1)
			local results: { SharedTypes.CommandResult } = TestUtils.results(created)
			expect(results[1].status).toBe("Unknown")
			expect(results[1].result).toBeNil()
			expect(#created.faults).toBe(1)
			assert(previous ~= nil, "Known indeterminate execution must remain correlatable")
			local outcome: Types.CommandOutcome = previous :: Types.CommandOutcome
			expect(outcome.status).toBe("Unknown")
			expect(outcome.result).toBeNil()
			expect(table.isfrozen(outcome)).toBe(true)
		end
	)
end

for _, fault: string in { "Throw", "Yield", "NotBoolean", "MissingReason", "LongReason", "UnexpectedReason" } do
	it(
		"contains authorization " .. fault .. " without entering the handler or reporting a definitive denial",
		function()
			local calls: number = 0

			local command: Types.CommandDefinition = definition(function(): Types.CommandHandlerResult
				calls += 1

				return { accepted = true, result = { sequenceId = 1 } }
			end)

			command.authorize = function(): (boolean, string?)
				if fault == "Throw" then
					error("AuthorizeFault")
				end

				if fault == "Yield" then
					coroutine.yield()
				end

				if fault == "NotBoolean" then
					return 1 :: any, nil
				end

				if fault == "MissingReason" then
					return false, nil
				end

				if fault == "LongReason" then
					return false, string.rep("x", 65)
				end

				return true, "Unexpected"
			end

			local created: TestUtils.Fixture = TestUtils.new({ command })
			fixture = created
			TestUtils.send(created, 1)
			expect(calls).toBe(0)
			local result: SharedTypes.CommandResult = TestUtils.results(created)[1]
			expect(result.status).toBe("Unknown")
			expect(result.reason).toBe("CommandAuthorizationFault")
		end
	)
end

it("keeps schema-owned immutable earlier outcomes and hides current, future and other-connection requests", function()
	local authorResult: any = { sequenceId = 17 }

	local created: TestUtils.Fixture = TestUtils.new({
		definition(function(context: Types.CommandContext): Types.CommandHandlerResult
			local current: TestUtils.Fixture = fixture :: TestUtils.Fixture
			expect(context:GetPriorOutcome(context.requestId)).toBeNil()
			expect(context:GetPriorOutcome(context.requestId + 1)).toBeNil()
			expect(context:GetPriorOutcome(-1)).toBeNil()

			if context.player == current.other then
				expect(context:GetPriorOutcome(1)).toBeNil()
			elseif context.requestId == 2 then
				local previous: Types.CommandOutcome? = context:GetPriorOutcome(1)
				assert(previous ~= nil, "Expected same-connection completed result")
				expect(previous.commandId).toBe("Game.Command")
				expect(previous.result).toEqual({ sequenceId = 17 })
				expect(table.isfrozen(previous.result)).toBe(true)
				expect(previous.targetActor).toBeNil()
			end

			return { accepted = true, result = authorResult }
		end),
	})

	fixture = created
	TestUtils.send(created, 1)
	authorResult.sequenceId = 99
	TestUtils.send(created, 2)
	TestUtils.send(created, 2, nil, nil, nil, created.other)
	expect(#created.faults).toBe(0)
	expect(TestUtils.results(created)[1].result.sequenceId).toBe(17)
end)

for _, bound: string in { "Count", "Bytes", "Lifetime" } do
	it("makes evicted outcomes deterministically unavailable at the " .. bound .. " bound", function()
		local limits: Types.ServerCommandLimits = { maxHistory = 1 }

		if bound == "Bytes" then
			limits.maxHistory = nil
			limits.maxHistoryBytes = 1
		end

		if bound == "Lifetime" then
			limits.maxHistory = nil
			limits.historySeconds = 1
		end

		local created: TestUtils.Fixture = TestUtils.new({
			definition(function(context: Types.CommandContext): Types.CommandHandlerResult
				if context.requestId == 3 then
					expect(context:GetPriorOutcome(1)).toBeNil()
				end

				return { accepted = true, result = { sequenceId = context.requestId } }
			end),
		}, limits)

		fixture = created
		TestUtils.send(created, 1)
		TestUtils.send(created, 2)
		created.now += 2
		TestUtils.send(created, 3)
		expect(created.faults).toEqual({})
	end)
end

it("clears history and pending execution on disconnect without blocking another connection", function()
	local created: TestUtils.Fixture = TestUtils.new({
		definition(function(context: Types.CommandContext): Types.CommandHandlerResult
			if context.requestId == 2 then
				expect(context:GetPriorOutcome(1)).toBeNil()
			end

			return { accepted = true, result = { sequenceId = 1 } }
		end),
	})

	fixture = created
	TestUtils.send(created, 1)
	AwarenessUtils.close(created.base, created.player)
	local admitted: boolean, reason: string? = TestUtils.send(created, 2)
	expect(admitted).toBe(false)
	expect(reason).toBe("ClientNotReady")
	TestUtils.send(created, 2, nil, nil, nil, created.other)
	expect(TestUtils.results(created, created.other)[1].status).toBe("Accepted")
	expect(created.faults).toEqual({})
end)
