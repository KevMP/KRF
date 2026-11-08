--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local Registry = require(KRF.server.Networking.CommandRegistry)
local TestUtils = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)
local fixture: TestUtils.Fixture? = nil

afterEach(function()
	TestUtils.destroy(fixture)
	fixture = nil
end)

local function definitions(): { Types.CommandDefinition }
	return { TestUtils.definition("Game.Command"), TestUtils.definition("Game.Stop") }
end

-- Sends one request per call without dispatching, so admission bounds stay observable.
local function sender(created: TestUtils.Fixture, player: Player?): (string) -> (boolean, string?)
	local nextId: number = 0

	return function(commandId: string): (boolean, string?)
		nextId += 1

		return created.runtime:Handle(
			player or created.player,
			TestUtils.request(created, nextId, commandId, player, nil, nil)
		)
	end
end

local function fill(send: (string) -> (boolean, string?), commandId: string): (number, string?)
	local admitted: number = 0

	while true do
		local accepted: boolean, reason: string? = send(commandId)

		if not accepted then
			return admitted, reason
		end

		admitted += 1
	end
end

it("keeps per-connection rate headroom that only follow-ups may use", function()
	local created: TestUtils.Fixture = TestUtils.new(definitions(), nil, { "Game.Stop" })
	fixture = created
	local send = sender(created)

	local ordinary: number, ordinaryReason: string? = fill(send, "Game.Command")
	expect(ordinary).toBe(56)
	expect(ordinaryReason).toBe("CommandRateLimited")

	-- Follow-ups share the same total window bound and never exceed it.
	local followUps: number, followUpReason: string? = fill(send, "Game.Stop")
	expect(followUps).toBe(8)
	expect(followUpReason).toBe("CommandRateLimited")
end)

it("keeps per-connection queue headroom that only follow-ups may use", function()
	local created: TestUtils.Fixture = TestUtils.new(
		definitions(),
		{ maxRequests = 1000, maxBytes = 1048576 },
		{ "Game.Stop" }
	)

	fixture = created
	local send = sender(created)

	local ordinary: number, ordinaryReason: string? = fill(send, "Game.Command")
	expect(ordinary).toBe(56)
	expect(ordinaryReason).toBe("CommandQueueFull")

	local followUps: number, followUpReason: string? = fill(send, "Game.Stop")
	expect(followUps).toBe(8)
	expect(followUpReason).toBe("CommandQueueFull")
	expect((created.runtime:_GetPendingForTests())).toBe(64)
end)

it("admits a follow-up after other clients saturate the shared global budget", function()
	local created: TestUtils.Fixture = TestUtils.new(definitions(), { maxGlobalRequests = 16 }, { "Game.Stop" })

	fixture = created
	local mine = sender(created)
	local theirs = sender(created, created.other)

	-- Two protected band attempts each, then a shared pool of 16 - 4 - 2 follow-up slots.
	expect((fill(mine, "Game.Command"))).toBe(12)
	local ordinary: number, reason: string? = fill(theirs, "Game.Command")
	expect(ordinary).toBe(2)
	expect(reason).toBe("CommandGlobalRateLimited")

	-- Each connection may hold one of the two global follow-up slots.
	expect((theirs("Game.Stop"))).toBe(true)
	expect((theirs("Game.Stop"))).toBe(false)
	expect((mine("Game.Stop"))).toBe(true)
	expect((mine("Game.Stop"))).toBe(false)
end)

it("dispatches admitted follow-ups behind earlier commands in connection FIFO order", function()
	local handled: { string } = {}

	local function recording(id: string): Types.CommandDefinition
		local definition: Types.CommandDefinition = TestUtils.definition(id)

		definition.handle = function(): Types.CommandHandlerResult
			table.insert(handled, id)

			return { accepted = true }
		end

		return definition
	end

	local created: TestUtils.Fixture = TestUtils.new(
		{ recording("Game.Command"), recording("Game.Stop") },
		nil,
		{ "Game.Stop" }
	)

	fixture = created
	local send = sender(created)
	fill(send, "Game.Command")
	expect((send("Game.Stop"))).toBe(true)

	for _ = 1, 16 do
		created.runtime:Step()
		TestUtils.results(created)
	end

	expect(#handled).toBe(57)

	expect(handled[56]).toBe("Game.Command")
	expect(handled[57]).toBe("Game.Stop")
end)

it("keeps the full bounds for ordinary commands when no follow-ups are classified", function()
	local created: TestUtils.Fixture = TestUtils.new(definitions())
	fixture = created
	local send = sender(created)

	local ordinary: number, reason: string? = fill(send, "Game.Command")
	expect(ordinary).toBe(64)
	expect(reason).toBe("CommandRateLimited")
	expect((send("Game.Stop"))).toBe(false)
end)

it("classifies only framework-named follow-ups and rejects unknown names", function()
	local catalog: Types.PreparedCommandCatalog? = Registry.Prepare(definitions(), { "Game.Stop" })
	assert(catalog ~= nil, "Expected a prepared catalog")
	expect(catalog.definitionsById["Game.Stop"].followUp).toBe(true)
	expect(catalog.definitionsById["Game.Command"].followUp).toBe(false)

	local missing: Types.PreparedCommandCatalog?, reason: string? = Registry.Prepare(definitions(), { "Game.Missing" })
	expect(missing).toBeNil()
	expect(reason).toBe("CommandFollowUpUnknown")

	-- Consumers cannot classify their own commands through the definition table.
	local definition: any = TestUtils.definition("Game.Sneaky")
	definition.followUp = true
	local refused: Types.PreparedCommandCatalog?, fieldReason: string? = Registry.Prepare({ definition })
	expect(refused).toBeNil()
	expect(fieldReason).toBe("CommandFieldUnknown")
end)

-- Saturates both Ready connections with ordinary commands under one global bound.
local function saturate(created: TestUtils.Fixture): ((string) -> (boolean, string?), (string) -> (boolean, string?))
	local mine = sender(created)
	local theirs = sender(created, created.other)
	fill(mine, "Game.Command")
	fill(theirs, "Game.Command")
	expect((theirs("Game.Command"))).toBe(false)

	return mine, theirs
end

for _, case in
	{
		{ label = "attempt bytes", limits = { maxGlobalBytes = 176 } },
		{ label = "queued requests", limits = { maxGlobalQueuedRequests = 16 } },
		{ label = "queued bytes", limits = { maxGlobalQueuedBytes = 176 } },
	} :: { { label: string, limits: Types.ServerCommandLimits } }
do
	it("keeps a bounded per-connection follow-up share of the global " .. case.label, function()
		local created: TestUtils.Fixture = TestUtils.new(definitions(), case.limits, { "Game.Stop" })
		fixture = created
		local mine, theirs = saturate(created)

		expect((theirs("Game.Stop"))).toBe(true)
		expect((theirs("Game.Stop"))).toBe(false)
		expect((mine("Game.Stop"))).toBe(true)
	end)
end

it("returns queued follow-up reserve when the follow-up dispatches", function()
	local created: TestUtils.Fixture = TestUtils.new(
		definitions(),
		{ maxGlobalQueuedRequests = 16, maxGlobalQueuedBytes = 176 },
		{ "Game.Stop" }
	)

	fixture = created
	local _, theirs = saturate(created)
	expect((theirs("Game.Stop"))).toBe(true)

	for _ = 1, 4 do
		created.runtime:Step()
		TestUtils.results(created)
		TestUtils.results(created, created.other)
	end

	expect((created.runtime:_GetPendingForTests())).toBe(0)
	expect((theirs("Game.Stop"))).toBe(true)
end)
