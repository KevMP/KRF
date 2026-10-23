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
local Constants = require(KRF.shared.Networking.utils.CommandConstants)
local TestUtils = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)

local fixture: TestUtils.Fixture? = nil

afterEach(function()
	TestUtils.destroy(fixture)
	fixture = nil
end)

local function definition(handle: Types.CommandHandler, authorize: Types.CommandAuthorize?): Types.CommandDefinition
	return {
		id = "Game.Command",
		target = "None",
		request = Schema.U8,
		result = Schema.U16,
		authorize = authorize or function(): (boolean, string?)
			return true, nil
		end,
		handle = handle,
	}
end

it("validates and authorizes before invoking a non-yielding handler and queues the schema-owned result", function()
	local order: { string } = {}

	local created: TestUtils.Fixture = TestUtils.new({
		definition(function(context: Types.CommandContext, request: any): Types.CommandHandlerResult
			table.insert(order, "Handle")
			expect(context.player).toBe((fixture :: TestUtils.Fixture).player)
			expect(context.actor).toBeNil()
			expect(context.commandId).toBe("Game.Command")
			expect(context.requestId).toBe(1)
			expect(request).toBe(7)

			return { accepted = true, result = 1000 }
		end, function(_context: Types.CommandContext, request: any): (boolean, string?)
			table.insert(order, "Authorize")
			expect(request).toBe(7)

			return true, nil
		end),
	})

	fixture = created
	local admitted: boolean, reason: string? = TestUtils.send(created, 1, 7)
	expect(admitted).toBe(true)
	expect(reason).toBeNil()
	expect(order).toEqual({ "Authorize", "Handle" })
	expect(#created.base.deliveries).toBe(0)
	local results: { SharedTypes.CommandResult } = TestUtils.results(created)
	expect(#results).toBe(1)
	expect(results[1].status).toBe("Accepted")
	expect(results[1].result).toBe(1000)
end)

it("denies authorization without invoking the handler and preserves the bounded semantic reason", function()
	local calls: number = 0

	local created: TestUtils.Fixture = TestUtils.new({
		definition(function(): Types.CommandHandlerResult
			calls += 1

			return { accepted = true, result = 1 }
		end, function(): (boolean, string?)
			return false, "OutOfRange"
		end),
	})

	fixture = created
	TestUtils.send(created, 1, 7)
	expect(calls).toBe(0)
	local results: { SharedTypes.CommandResult } = TestUtils.results(created)
	expect(results[1].status).toBe("Rejected")
	expect(results[1].reason).toBe("OutOfRange")
end)

it("never enters author callbacks for non-Ready, malformed, unknown, duplicate or non-increasing requests", function()
	local calls: number = 0

	local created: TestUtils.Fixture = TestUtils.new({
		definition(function(): Types.CommandHandlerResult
			calls += 1

			return { accepted = true, result = 1 }
		end),
	})

	fixture = created
	created.base.readyPlayers[created.player] = nil
	TestUtils.send(created, 1, 7)
	expect(calls).toBe(0)
	created.base.readyPlayers[created.player] = true
	created.runtime:Handle(created.player, buffer.fromstring("unknown"))
	local invalid: buffer = TestUtils.request(created, 1, nil, nil, nil, 7)
	buffer.writeu16(invalid, 1, 100)
	created.runtime:Handle(created.player, invalid)
	created.runtime:Handle(created.player, buffer.create(Constants.MAX_REQUEST_BYTES + 1))
	TestUtils.send(created, 2, 7)
	TestUtils.send(created, 2, 7)
	TestUtils.send(created, 1, 7)
	created.runtime:Handle(created.player, TestUtils.request(created, 3, nil, nil, nil, 7), "extra")
	expect(calls).toBe(1)
	expect(#TestUtils.results(created)).toBe(1)
end)

it("reserves outbound result capacity before any author callback and executes no effects when full", function()
	local calls: number = 0

	local created: TestUtils.Fixture = TestUtils.new({
		definition(function(): Types.CommandHandlerResult
			calls += 1

			return { accepted = true, result = 1 }
		end, function(): (boolean, string?)
			calls += 1

			return true, nil
		end),
	})

	fixture = created

	created.awareness.ReserveCommandResult = function(): (Types.CommandReservation?, string?)
		return nil, "CommandOutboundFull"
	end

	TestUtils.send(created, 1, 7)
	expect(calls).toBe(0)
	expect(#TestUtils.results(created)).toBe(0)
end)

it("keeps same-connection execution serial under reentry and installs history before the next handler", function()
	local order: { string } = {}

	local created: TestUtils.Fixture = TestUtils.new({
		definition(function(context: Types.CommandContext, request: any): Types.CommandHandlerResult
			table.insert(order, "Enter" .. tostring(request))

			if request == 1 then
				TestUtils.send(fixture :: TestUtils.Fixture, 2, 2)
				expect(order).toEqual({ "Enter1" })
			else
				local prior: Types.CommandOutcome? = context:GetPriorOutcome(1)
				assert(prior ~= nil, "History must be installed before request two")
				expect(prior.result).toBe(11)
			end

			table.insert(order, "Exit" .. tostring(request))

			return { accepted = true, result = request + 10 }
		end),
	})

	fixture = created
	TestUtils.send(created, 1, 1)
	expect(order).toEqual({ "Enter1", "Exit1", "Enter2", "Exit2" })
	expect(#TestUtils.results(created)).toBe(2)
end)

it("bounds reentrant unprocessed work and request/byte admission without amplifying rejected output", function()
	local calls: number = 0

	local created: TestUtils.Fixture = TestUtils.new({
		definition(function(_context: Types.CommandContext, request: any): Types.CommandHandlerResult
			calls += 1

			if request == 1 then
				for id: number = 2, 10 do
					TestUtils.send(fixture :: TestUtils.Fixture, id, id)
				end
			end

			return { accepted = true, result = request }
		end),
	}, { maxQueuedRequests = 1, maxQueuedBytes = 64, maxRequests = 10, maxBytes = 128 })

	fixture = created
	TestUtils.send(created, 1, 1)
	expect(calls).toBe(2)
	TestUtils.send(created, 11, 11)
	expect(calls).toBe(2)
	expect(#TestUtils.results(created)).toBe(2)
	created.now += 2
	TestUtils.send(created, 12, 12)
	expect(calls).toBe(3)
end)
