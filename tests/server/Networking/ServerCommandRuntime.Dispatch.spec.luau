--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.server.Networking.types)
local Runtime = require(ReplicatedStorage.Packages.KRF.server.Networking.ServerCommandRuntime)
local Registry = require(ReplicatedStorage.Packages.KRF.server.Networking.CommandRegistry)
local TestUtils = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)
local AwarenessUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture? = nil

afterEach(function()
	TestUtils.destroy(fixture)
	fixture = nil
end)

local function create(limits: Types.ServerCommandLimits, handler: Types.CommandHandler?): TestUtils.Fixture
	local command: Types.CommandDefinition = TestUtils.definition("Game.Command")

	if handler ~= nil then
		command.handle = handler
	end

	local created = TestUtils.new({ command }, limits)
	fixture = created

	return created
end

local function admit(created: TestUtils.Fixture, id: number, player: Player?): (boolean, string?)
	return created.runtime:Handle(player or created.player, TestUtils.request(created, id, nil, nil, nil, nil))
end

it("admits a valid request without executing authoritative callbacks on the ingress stack", function()
	local calls: number = 0

	local command: Types.CommandDefinition = TestUtils.definition("Game.Command")

	command.handle = function(): Types.CommandHandlerResult
		calls += 1

		return { accepted = true }
	end

	local created: TestUtils.Fixture = TestUtils.new({ command })
	fixture = created

	local admitted: boolean, reason: string? =
		created.runtime:Handle(created.player, TestUtils.request(created, 1, nil, nil, nil, nil))

	expect(admitted).toBe(true)
	expect(reason).toBeNil()
	expect(calls).toBe(0)
	expect((created.runtime:Step())).toBe(1)
	expect(calls).toBe(1)
end)

it(
	"rotates busy and intermittent connections with one bounded opportunity and installs earlier outcomes first",
	function()
		local order: { string } = {}

		local created = create(
			{ maxDispatchRequests = 1, maxDispatchVisits = 1 },
			function(context): Types.CommandHandlerResult
				local current = fixture :: TestUtils.Fixture

				local name = if context.player == current.player
					then "A"
					elseif context.player == current.other then "B"
					else "C"

				if context.requestId > 1 then
					local prior = context:GetPriorOutcome(context.requestId - 1)
					assert(prior ~= nil, "Previous outcome must precede the next handler")
					expect(prior.status).toBe("Accepted")
				end

				table.insert(order, name .. context.requestId)

				return { accepted = true }
			end
		)

		for id = 1, 3 do
			admit(created, id)
			admit(created, id, created.other)
		end

		created.runtime:Step()
		created.runtime:Step()
		local intermittent = AwarenessUtils.player(created.base)
		AwarenessUtils.ready(created.base, intermittent)
		admit(created, 1, intermittent)

		for _ = 1, 5 do
			local dispatched, visits = created.runtime:Step()
			expect(dispatched).toBe(1)
			expect(visits).toBe(1)
		end

		expect(order).toEqual({ "A1", "B1", "A2", "B2", "C1", "A3", "B3" })
		local jobs, bytes = created.runtime:_GetPendingForTests()
		expect(jobs).toBe(0)
		expect(bytes).toBe(0)
	end
)

for _, bound in { "Count", "Bytes" } do
	it("bounds aggregate queued " .. bound .. " across individually valid clients and consumes refused ids", function()
		local options: Types.ServerCommandLimits = { maxGlobalQueuedRequests = 2 }

		if bound == "Bytes" then
			options.maxGlobalQueuedRequests = 10
			options.maxGlobalQueuedBytes = 22
		end

		local created = create(options)
		expect((admit(created, 1))).toBe(true)
		expect((admit(created, 1, created.other))).toBe(true)
		local admitted, reason = admit(created, 2, created.other)
		expect(admitted).toBe(false)
		expect(reason).toBe("CommandGlobalQueueFull")
		local jobs, bytes = created.runtime:_GetPendingForTests()
		expect(jobs).toBe(2)
		expect(bytes).toBe(22)
		created.runtime:Step()
		admitted, reason = admit(created, 2, created.other)
		expect(admitted).toBe(false)
		expect(reason).toBe("ReplayedRequestId")
		expect((admit(created, 3, created.other))).toBe(true)
	end)
end

for _, bound in { "Count", "Bytes" } do
	it("bounds global admission " .. bound .. " through dispatch and disconnect until its window resets", function()
		local options: Types.ServerCommandLimits = { maxGlobalRequests = 2 }

		if bound == "Bytes" then
			options.maxGlobalRequests = 10
			options.maxGlobalBytes = 22
		end

		local created = create(options)
		admit(created, 1)
		admit(created, 1, created.other)
		created.runtime:Step()
		AwarenessUtils.close(created.base, created.player)
		local admitted, reason = admit(created, 2, created.other)
		expect(admitted).toBe(false)
		expect(reason).toBe("CommandGlobalRateLimited")
		created.now += 1
		expect((admit(created, 3, created.other))).toBe(true)
	end)
end

it(
	"charges malformed admission attempts globally before decoding instead of allowing unlimited refused work",
	function()
		local created = create({ maxGlobalRequests = 2 })
		created.runtime:Handle(created.player, buffer.create(0))
		created.runtime:Handle(created.other, buffer.create(0))
		local admitted, reason = admit(created, 1)
		expect(admitted).toBe(false)
		expect(reason).toBe("CommandGlobalRateLimited")
		expect((created.runtime:_GetPendingForTests())).toBe(0)
	end
)

it("defers a blocked FIFO head without effects or reordering and visits other eligible clients", function()
	local order: { number } = {}

	local created = create(
		{ maxDispatchRequests = 1, maxDispatchVisits = 2 },
		function(context): Types.CommandHandlerResult
			table.insert(order, context.requestId)

			return { accepted = true }
		end
	)

	local reserve = created.awareness.ReserveCommandResult
	local blocked = true
	local attempts = 0

	created.awareness.ReserveCommandResult = function(
		self: Types.ActorAwarenessRuntime,
		player: Player,
		maximum: number
	): (Types.CommandReservation?, string?)
		attempts += 1

		if blocked and player == created.player then
			return nil, "CommandOutboundFull"
		end

		return reserve(self, player, maximum)
	end

	admit(created, 1)
	admit(created, 2)
	admit(created, 10, created.other)
	local dispatched, visits = created.runtime:Step()
	expect(dispatched).toBe(1)
	expect(visits).toBe(2)
	expect(attempts).toBe(2)
	expect(order).toEqual({ 10 })
	expect((created.runtime:_GetPendingForTests())).toBe(2)
	dispatched, visits = created.runtime:Step()
	expect(dispatched).toBe(0)
	expect(visits).toBe(1)
	blocked = false
	created.runtime:Step()
	created.runtime:Step()
	expect(order).toEqual({ 10, 1, 2 })
	expect(#TestUtils.results(created)).toBe(2)
end)

for _, operation in { "Disconnect", "Destroy", "Fault" } do
	it(
		"keeps in-progress capacity charged through " .. operation .. " and releases queued work exactly once",
		function()
			local calls = 0

			local created = create(
				{ maxGlobalQueuedRequests = 2, maxDispatchRequests = 1 },
				function(context): Types.CommandHandlerResult
					calls += 1
					local current = fixture :: TestUtils.Fixture
					local nested, visits = current.runtime:Step()
					expect(nested).toBe(0)
					expect(visits).toBe(0)

					if operation == "Disconnect" then
						AwarenessUtils.close(current.base, context.player)
						AwarenessUtils.close(current.base, context.player)
						expect((current.runtime:_GetPendingForTests())).toBe(1)
						expect((admit(current, 1, current.other))).toBe(true)
						local admitted, reason = admit(current, 2, current.other)
						expect(admitted).toBe(false)
						expect(reason).toBe("CommandGlobalQueueFull")
					elseif operation == "Destroy" then
						current.runtime:Destroy()
						current.runtime:Destroy()
						expect((current.runtime:_GetPendingForTests())).toBe(1)
					else
						error("AfterEffect")
					end

					return { accepted = true }
				end
			)

			admit(created, 1)
			admit(created, 2)
			created.runtime:Step()

			if operation == "Disconnect" then
				AwarenessUtils.close(created.base, created.other)
			end

			created.runtime:Destroy()
			created.runtime:Destroy()
			local jobs, bytes = created.runtime:_GetPendingForTests()
			expect(jobs).toBe(0)
			expect(bytes).toBe(0)
			expect(calls).toBe(1)
			expect(created.faults).toEqual(if operation == "Fault" then { "CommandHandlerFault" } else {})
		end
	)
end

it("unlinks a closed dispatch cursor and discards queued work that loses readiness before its turn", function()
	local calls = 0

	local created = create({}, function(): Types.CommandHandlerResult
		calls += 1

		return { accepted = true }
	end)

	admit(created, 1)
	admit(created, 1, created.other)
	AwarenessUtils.close(created.base, created.player)
	expect((created.runtime:_GetPendingForTests())).toBe(1)
	created.base.readyPlayers[created.other] = nil
	local dispatched, visits = created.runtime:Step()
	expect(dispatched).toBe(0)
	expect(visits).toBe(1)
	expect(calls).toBe(0)
	expect((created.runtime:_GetPendingForTests())).toBe(0)
end)

it("cancels a reserved result on an internal post-effect fault and releases the invocation charge", function()
	local created = create({})
	local cancelled = 0

	created.dependencies.ScheduleTimeout = function(): () -> ()
		error("HistoryTimerFault")
	end

	created.awareness.ReserveCommandResult = function(): (Types.CommandReservation?, string?)
		return {
			Commit = function(): boolean
				return true
			end,
			Cancel = function()
				cancelled += 1
			end,
		},
			nil
	end

	admit(created, 1)
	created.runtime:Step()
	expect(cancelled).toBe(1)
	expect(created.closed).toEqual({ created.player })
	expect(created.faults).toEqual({ "CommandInternalFault" })
	expect((created.runtime:_GetPendingForTests())).toBe(0)
end)

it("rechecks ownership after reservation reentry closes the connection before any author callback", function()
	local callbacks = 0

	local command = TestUtils.definition("Game.Command")

	command.authorize = function(): (boolean, string?)
		callbacks += 1

		return true, nil
	end

	command.handle = function(): Types.CommandHandlerResult
		callbacks += 1

		return { accepted = true }
	end

	local created = TestUtils.new({ command })
	fixture = created
	local reserve = created.awareness.ReserveCommandResult

	created.awareness.ReserveCommandResult = function(
		self: Types.ActorAwarenessRuntime,
		player: Player,
		maximum: number
	): (Types.CommandReservation?, string?)
		local token, reason = reserve(self, player, maximum)
		AwarenessUtils.close(created.base, player)

		return token, reason
	end

	admit(created, 1)
	admit(created, 2)
	created.runtime:Step()
	expect(callbacks).toBe(0)
	local jobs, bytes = created.runtime:_GetPendingForTests()
	expect(jobs).toBe(0)
	expect(bytes).toBe(0)
	expect(created.faults).toEqual({})
end)

it("rejects fractional dispatch limits instead of executing beyond an injected work cap", function()
	local created = create({})

	expect(function()
		Runtime.new(
			{ definitionsById = {}, orderedDefinitions = {} },
			created.protocol,
			created.dependencies,
			{ maxDispatchRequests = 0.5 }
		)
	end).toThrow("InvalidCommandLimit")
end)

for _, disabled in { "Admission", "Queue", "Dispatch", "Visits" } do
	it("supports a zero " .. disabled .. " budget without executing or leaking work", function()
		local options: Types.ServerCommandLimits = {}

		if disabled == "Admission" then
			options.maxGlobalRequests = 0
		elseif disabled == "Queue" then
			options.maxGlobalQueuedRequests = 0
		elseif disabled == "Dispatch" then
			options.maxDispatchRequests = 0
		else
			options.maxDispatchVisits = 0
		end

		local created = create(options)
		local admitted, reason = admit(created, 1)

		if disabled == "Admission" or disabled == "Queue" then
			expect(admitted).toBe(false)

			expect(reason).toBe(
				if disabled == "Admission" then "CommandGlobalRateLimited" else "CommandGlobalQueueFull"
			)
		else
			expect(admitted).toBe(true)
			local dispatched, visits = created.runtime:Step()
			expect(dispatched).toBe(0)
			expect(visits).toBe(0)
		end

		created.runtime:Destroy()
		local jobs, bytes = created.runtime:_GetPendingForTests()
		expect(jobs).toBe(0)
		expect(bytes).toBe(0)
	end)
end

it("releases all queued capacity even when the owned subscription teardown faults", function()
	local created = create({})
	created.runtime:Destroy()

	created.dependencies.ObserveClientClosed = function(): () -> ()
		return function()
			error("SubscriptionCleanupFault")
		end
	end

	local catalog = assert(Registry.Prepare({ TestUtils.definition("Game.Command") }))

	created.runtime = Runtime.new(catalog, created.protocol, created.dependencies)
	admit(created, 1)
	admit(created, 2, created.other)
	local completed = pcall(created.runtime.Destroy, created.runtime)
	expect(completed).toBe(true)
	local jobs, bytes = created.runtime:_GetPendingForTests()
	expect(jobs).toBe(0)
	expect(bytes).toBe(0)
end)
