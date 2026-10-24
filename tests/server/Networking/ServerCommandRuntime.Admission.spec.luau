--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.server.Networking.types)
local Schema = require(ReplicatedStorage.Packages.KRF.shared.Networking.Schema)
local TestUtils = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)
local AwarenessUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture? = nil

afterEach(function()
	TestUtils.destroy(fixture)
	fixture = nil
end)

it("gives every Ready client a protected part of an eight-client burst", function()
	local created: TestUtils.Fixture = TestUtils.new({ TestUtils.definition("Game.Command") })
	fixture = created
	local players: { Player } = { created.player, created.other }

	for _ = 3, 8 do
		local player: Player = AwarenessUtils.player(created.base)
		AwarenessUtils.ready(created.base, player)
		table.insert(players, player)
	end

	local counts: { number } = {}

	for index, player in players do
		counts[index] = 0

		for id = 1, 64 do
			if created.runtime:Handle(player, TestUtils.request(created, id, nil, nil, nil, nil)) then
				counts[index] += 1
			end
		end
	end

	expect(counts).toEqual({ 64, 64, 64, 32, 8, 8, 8, 8 })
	expect((created.runtime:_GetPendingForTests())).toBe(256)
	created.runtime:Destroy()
	expect((created.runtime:_GetPendingForTests())).toBe(0)
end)

it("recovers a late client's protected attempts in the next window after earlier total exhaustion", function()
	local created: TestUtils.Fixture = TestUtils.new(
		{ TestUtils.definition("Game.Command") },
		{ maxGlobalRequests = 8 }
	)

	fixture = created
	AwarenessUtils.close(created.base, created.other)

	for id = 1, 8 do
		expect((created.runtime:Handle(created.player, TestUtils.request(created, id, nil, nil, nil, nil)))).toBe(true)
	end

	local late: Player = AwarenessUtils.player(created.base)
	AwarenessUtils.ready(created.base, late)
	expect((created.runtime:Handle(late, TestUtils.request(created, 1, nil, nil, nil, nil)))).toBe(false)
	created.now += 1

	for _ = 1, 16 do
		created.runtime:Handle(created.player, buffer.create(0))
	end

	expect((created.runtime:Handle(late, TestUtils.request(created, 1, nil, nil, nil, nil)))).toBe(true)
end)

it("rotates opportunities when the protected attempt budget has fewer slots than Ready clients", function()
	local created: TestUtils.Fixture = TestUtils.new(
		{ TestUtils.definition("Game.Command") },
		{ maxGlobalRequests = 2 }
	)

	fixture = created
	local late: Player = AwarenessUtils.player(created.base)
	AwarenessUtils.ready(created.base, late)
	local admitted = 0

	for id = 1, 6 do
		for _ = 1, 8 do
			created.runtime:Handle(created.player, buffer.create(0))
			created.runtime:Handle(created.other, buffer.create(0))
		end

		if created.runtime:Handle(late, TestUtils.request(created, id, nil, nil, nil, nil)) then
			admitted += 1
		end

		created.runtime:Step()
		created.now += 1
	end

	expect(admitted).toBe(2)
end)

it("releases protected and borrowed queue charges on disconnect and lets the remaining client use capacity", function()
	local created: TestUtils.Fixture = TestUtils.new(
		{ TestUtils.definition("Game.Command") },
		{ maxGlobalQueuedRequests = 8 }
	)

	fixture = created

	for id = 1, 8 do
		created.runtime:Handle(created.player, TestUtils.request(created, id, nil, nil, nil, nil))
	end

	AwarenessUtils.close(created.base, created.player)
	expect((created.runtime:_GetPendingForTests())).toBe(0)

	for id = 1, 8 do
		expect((created.runtime:Handle(created.other, TestUtils.request(created, id, nil, nil, nil, nil)))).toBe(true)
	end

	created.runtime:Step()
	expect(#TestUtils.results(created, created.other)).toBe(8)
	expect((created.runtime:_GetPendingForTests())).toBe(0)
end)

it("protects a maximum-schema request against unrelated byte pressure before any handler effect", function()
	local command: Types.CommandDefinition = TestUtils.definition("Game.Command")
	command.request = Schema.String(128)

	local created: TestUtils.Fixture = TestUtils.new({ command }, { maxGlobalBytes = 512, maxGlobalQueuedBytes = 512 })
	fixture = created
	local late: Player = AwarenessUtils.player(created.base)
	AwarenessUtils.ready(created.base, late)

	for id = 1, 16 do
		created.runtime:Handle(created.player, TestUtils.request(created, id, nil, nil, nil, string.rep("x", 100)))
	end

	expect((created.runtime:Handle(late, TestUtils.request(created, 1, nil, nil, nil, string.rep("y", 128))))).toBe(
		true
	)

	created.runtime:Step()
	expect(#TestUtils.results(created, late)).toBe(1)
end)

it("protects a quiet Ready connection while a noisy connection borrows shared queue capacity", function()
	local created: TestUtils.Fixture = TestUtils.new({ TestUtils.definition("Game.Command") }, {
		maxGlobalQueuedRequests = 8,
	})

	fixture = created
	local admitted = 0

	for id = 1, 8 do
		if created.runtime:Handle(created.player, TestUtils.request(created, id, nil, nil, nil, nil)) then
			admitted += 1
		end
	end

	expect(admitted).toBe(7)
	expect((created.runtime:Handle(created.other, TestUtils.request(created, 1, nil, nil, nil, nil)))).toBe(true)
	expect((created.runtime:_GetPendingForTests())).toBe(8)
	created.runtime:Step()
	expect(#TestUtils.results(created)).toBe(7)
	expect(#TestUtils.results(created, created.other)).toBe(1)
end)

it("uses remainder slots without losing a three-client protected opportunity", function()
	local created: TestUtils.Fixture = TestUtils.new(
		{ TestUtils.definition("Game.Command") },
		{ maxGlobalQueuedRequests = 16 }
	)

	fixture = created
	local late: Player = AwarenessUtils.player(created.base)
	AwarenessUtils.ready(created.base, late)
	local counts: { number } = {}

	for index, player in { created.player, created.other, late } do
		counts[index] = 0

		for id = 1, 16 do
			if created.runtime:Handle(player, TestUtils.request(created, id, nil, nil, nil, nil)) then
				counts[index] += 1
			end
		end
	end

	expect(counts).toEqual({ 13, 1, 2 })
	expect((created.runtime:_GetPendingForTests())).toBe(16)
end)

it("protects every eight-client maximum-size request without byte-pool fragmentation", function()
	local command: Types.CommandDefinition = TestUtils.definition("Game.Command")
	-- Registry schemas reserve eight conservative prefix bytes; the compiled
	-- wire codec uses a narrower prefix for this maximum permitted String.
	command.request = Schema.String(16376)

	local created: TestUtils.Fixture = TestUtils.new({ command })
	fixture = created
	local players: { Player } = { created.player, created.other }

	for _ = 3, 8 do
		local player: Player = AwarenessUtils.player(created.base)
		AwarenessUtils.ready(created.base, player)
		table.insert(players, player)
	end

	for _, player in players do
		local admitted = 0

		for id = 1, 7 do
			if
				created.runtime:Handle(player, TestUtils.request(created, id, nil, nil, nil, string.rep("x", 16376)))
			then
				admitted += 1
			end
		end

		expect(admitted >= 1).toBe(true)
	end

	local _, bytes = created.runtime:_GetPendingForTests()
	expect(bytes <= 524288).toBe(true)
end)

it("protects a quiet connection's attempt budget from malformed traffic in every window", function()
	local created: TestUtils.Fixture = TestUtils.new({ TestUtils.definition("Game.Command") }, {
		maxGlobalRequests = 8,
	})

	fixture = created

	for window = 1, 3 do
		for _ = 1, 16 do
			created.runtime:Handle(created.player, buffer.create(0))
		end

		expect((created.runtime:Handle(created.other, TestUtils.request(created, window, nil, nil, nil, nil)))).toBe(
			true
		)

		created.runtime:Step()
		created.now += 1
	end

	expect(#TestUtils.results(created, created.other)).toBe(3)
end)

it("admits a newly Ready client after capacity recovery without evicting earlier commands", function()
	local created: TestUtils.Fixture = TestUtils.new({ TestUtils.definition("Game.Command") }, {
		maxGlobalQueuedRequests = 8,
	})

	fixture = created
	local admitted = 0

	for id = 1, 8 do
		if created.runtime:Handle(created.player, TestUtils.request(created, id, nil, nil, nil, nil)) then
			admitted += 1
		end
	end

	local late: Player = AwarenessUtils.player(created.base)
	AwarenessUtils.ready(created.base, late)
	created.runtime:Step()

	for id = 9, 16 do
		if created.runtime:Handle(created.player, TestUtils.request(created, id, nil, nil, nil, nil)) then
			admitted += 1
		end
	end

	expect((created.runtime:Handle(late, TestUtils.request(created, 1, nil, nil, nil, nil)))).toBe(true)
	created.runtime:Step()
	expect(#TestUtils.results(created, late)).toBe(1)
	expect(#TestUtils.results(created)).toBe(admitted)
end)
