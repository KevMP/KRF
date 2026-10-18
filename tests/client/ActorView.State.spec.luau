--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local PublicTypes = require(KRF.client.Actor.types)
local SignalTypes = require(KRF.shared.Signal.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)

local fixture: TestUtils.Fixture
beforeEach(function()
	fixture = TestUtils.new()
end)
afterEach(function()
	TestUtils.destroy(fixture)
end)

it("exposes stable domain ids, declared events and read-only event surfaces", function()
	TestUtils.baseline(fixture)
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
	expect(domain:GetId()).toBe("Game.Stamina")
	local event: SignalTypes.Event<any>? = domain:GetEvent("Depleted")
	assert(event ~= nil, "Declared semantic event must be available before it ever fires")
	expect(domain:GetEvent("Depleted")).toBe(event)
	expect(domain:GetEvent("Undeclared")).toBeNil()
	local replaced: boolean = pcall(function()
		(domain :: any).GetState = function(): any
			return {}
		end
	end)
	expect(replaced).toBe(false)
	for _, surface: any in
		{
			event,
			domain.OnChanged,
			TestUtils.view(fixture).OnModelChanged,
			fixture.runtime.registry.OnActorViewAdded,
			fixture.runtime.registry.OnActorViewRemoving,
		}
	do
		for _, member: string in { "Fire", "Destroy", "DisconnectAll" } do
			local readable: boolean, value: any = pcall(function(): any
				return surface[member]
			end)
			if readable then
				expect(value).toBeNil()
			end
		end
	end
end)

it("keeps an Optional nil domain visible through present and absent state transitions", function()
	TestUtils.baseline(fixture, nil, nil, nil, { ["Game.Owner"] = { value = nil } })
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture, "Game.Owner")
	local changes: { PublicTypes.DomainChange } = {}
	table.insert(
		fixture.connections,
		domain.OnChanged:Connect(function(change: PublicTypes.DomainChange)
			table.insert(changes, change)
		end)
	)
	TestUtils.commit(
		fixture,
		11,
		{ { domainId = "Game.Owner", patch = { kind = "Replace", value = { secret = "visible" } } } }
	)
	TestUtils.commit(fixture, 12, { { domainId = "Game.Owner", patch = { kind = "Replace", value = nil } } })
	expect(TestUtils.domain(fixture, "Game.Owner")).toBe(domain)
	expect(domain:GetState()).toBeNil()
	expect(changes).toEqual({
		{ current = { secret = "visible" }, source = "Commit" },
		{ previous = { secret = "visible" }, source = "Commit" },
	})
end)

for _, case: { eventId: string, payload: any } in
	{
		{ eventId = "Changed", payload = 0 },
		{ eventId = "Flag", payload = false },
		{ eventId = "Maybe", payload = nil },
	}
do
	it("dispatches the declared " .. case.eventId .. " event even with a falsy or nil payload", function()
		TestUtils.baseline(fixture)
		local event: SignalTypes.Event<any>? = TestUtils.domain(fixture, "Game.Counter"):GetEvent(case.eventId)
		assert(event ~= nil, "Expected declared semantic event")
		local delivered: { any } = {}
		table.insert(
			fixture.connections,
			event:Connect(function(...: any)
				table.insert(delivered, table.pack(...))
			end)
		)
		TestUtils.commit(
			fixture,
			11,
			{},
			{ { domainId = "Game.Counter", eventId = case.eventId, payload = case.payload } }
		)
		expect(#delivered).toBe(1)
		expect(delivered[1].n).toBe(1)
		expect(delivered[1][1]).toEqual(case.payload)
	end)
end

it("keeps handles, revisions, mutation and future typed views out of the public ActorView", function()
	TestUtils.baseline(fixture)
	local view: PublicTypes.ActorView = TestUtils.view(fixture)
	for _, member: string in
		{
			"handle",
			"revision",
			"generation",
			"consumer",
			"GetHandle",
			"GetRevision",
			"GetTags",
			"GetResources",
			"GetActions",
			"Apply",
			"SendReliable",
			"RequestResync",
		}
	do
		local readable: boolean, value: any = pcall(function(): any
			return (view :: any)[member]
		end)
		if readable then
			expect(value).toBeNil()
		end
	end
	local readable: boolean, byHandle: any = pcall(function(): any
		return (fixture.runtime.registry :: any).GetActorViewByHandle
	end)
	if readable then
		expect(byHandle).toBeNil()
	end
	local replaced: boolean = pcall(function()
		(view :: any).GetId = function(): string
			return "corrupted"
		end
	end)
	expect(replaced).toBe(false)
	expect(view:GetId()).toBe("ActorA")
end)

type MutationCase = { name: string, mutate: (any) -> () }
local mutations: { MutationCase } = {
	{
		name = "root Struct",
		mutate = function(state: any)
			state.current = 999
		end,
	},
	{
		name = "nested Struct",
		mutate = function(state: any)
			state.details.label = "corrupt"
		end,
	},
	{
		name = "Map",
		mutate = function(state: any)
			state.effects.Burn = nil
		end,
	},
	{
		name = "nested Map value",
		mutate = function(state: any)
			state.effects.Burn.stacks = 9
		end,
	},
	{
		name = "Array",
		mutate = function(state: any)
			table.remove(state.slots, 1)
		end,
	},
	{
		name = "Array element",
		mutate = function(state: any)
			state.slots[1].name = "corrupt"
		end,
	},
}
for _, case: MutationCase in mutations do
	it("prevents consumer mutation of " .. case.name, function()
		TestUtils.baseline(fixture)
		local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
		local state: any = domain:GetState()
		local mutated: boolean = pcall(case.mutate, state)
		expect(mutated).toBe(false)
		expect(domain:GetState()).toEqual(TestUtils.truth()["Game.Stamina"].value)
	end)
end

it("retains previous immutable snapshots and shares untouched domains and subtrees across small patches", function()
	TestUtils.baseline(fixture)
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
	local previous: any = domain:GetState()
	local owner: any = TestUtils.domain(fixture, "Game.Owner"):GetState()
	TestUtils.commit(fixture, 11, { TestUtils.patch(75) })
	local current: any = domain:GetState()
	expect(previous.current).toBe(100)
	expect(current.current).toBe(75)
	expect(rawequal(previous, current)).toBe(false)
	expect(rawequal(previous.details, current.details)).toBe(true)
	expect(rawequal(previous.effects, current.effects)).toBe(true)
	expect(rawequal(previous.slots, current.slots)).toBe(true)
	expect(rawequal(owner, TestUtils.domain(fixture, "Game.Owner"):GetState())).toBe(true)
end)

it("delivers complete immutable previous/current change values with Commit source exactly once", function()
	TestUtils.baseline(fixture)
	local domain: PublicTypes.DomainView = TestUtils.domain(fixture)
	local previous: any = domain:GetState()
	local changes: { PublicTypes.DomainChange } = {}
	table.insert(
		fixture.connections,
		domain.OnChanged:Connect(function(change: PublicTypes.DomainChange)
			table.insert(changes, change)
		end)
	)
	TestUtils.commit(fixture, 11, { TestUtils.patch(75) })
	expect(#changes).toBe(1)
	expect(changes[1]).toEqual({
		previous = previous,
		current = TestUtils.truth(75)["Game.Stamina"].value,
		source = "Commit",
	})
	expect(table.isfrozen(changes[1])).toBe(true)
	expect(table.isfrozen(changes[1].previous.effects.Burn)).toBe(true)
	expect(table.isfrozen(changes[1].current.effects.Burn)).toBe(true)
	TestUtils.commit(fixture, 12, { TestUtils.patch(75) })
	expect(#changes).toBe(1)
end)

it("owns and recursively freezes semantic payloads before any consumer can mutate another consumer's value", function()
	TestUtils.baseline(fixture)
	local event: SignalTypes.Event<any>? = TestUtils.domain(fixture):GetEvent("Changed")
	assert(event ~= nil, "Expected declared event")
	local seen: { any } = {}
	local mutationResults: { boolean } = {}
	for _ = 1, 2 do
		table.insert(
			fixture.connections,
			event:Connect(function(payload: any)
				table.insert(seen, { amount = payload.amount, history = table.clone(payload.history) })
				local mutated: boolean = pcall(function()
					payload.history[1] = 999
				end)
				table.insert(mutationResults, mutated)
				local rootMutated: boolean = pcall(function()
					payload.amount = 999
				end)
				table.insert(mutationResults, rootMutated)
			end)
		)
	end
	local payload: any = { amount = 25, history = { 100, 75 } }
	fixture.runtime.consumer.OnCommitReady(
		TestUtils.actor(fixture),
		11,
		{},
		{ { domainId = "Game.Stamina", eventId = "Changed", payload = payload } }
	)
	expect(seen).toEqual({ { amount = 25, history = { 100, 75 } }, { amount = 25, history = { 100, 75 } } })
	expect(mutationResults).toEqual({ false, false, false, false })
	-- Either copy or take immutable ownership of freshly decoded input. Mutable
	-- scratch aliases must never change an already-dispatched payload.
	pcall(function()
		payload.history[1] = 1
	end)
	expect(seen[1].history).toEqual({ 100, 75 })
end)

it("applies a mixed schema patch to the exact complete authoritative state", function()
	TestUtils.baseline(fixture)
	local patches: { SharedNetworkingTypes.ActorDomainPatch } = {
		{
			domainId = "Game.Stamina",
			patch = {
				kind = "Struct",
				fields = {
					current = { kind = "Replace", value = 40 },
					details = { kind = "Struct", fields = { enabled = { kind = "Replace", value = false } } },
					effects = {
						kind = "Map",
						entries = { Burn = { stacks = 3 }, Poison = { stacks = 1 } },
						removed = { "Slow" },
					},
					slots = { kind = "Replace", value = { { name = "Ether" } } },
					target = { kind = "Replace", value = { id = 12 } },
				},
			},
		},
	}
	TestUtils.commit(fixture, 11, patches)
	expect(TestUtils.domain(fixture):GetState()).toEqual({
		current = 40,
		max = 100,
		details = { label = "Stamina", enabled = false },
		effects = { Burn = { stacks = 3 }, Poison = { stacks = 1 } },
		slots = { { name = "Ether" } },
		target = { id = 12 },
	})
	TestUtils.commit(fixture, 12, {
		{
			domainId = "Game.Stamina",
			patch = { kind = "Struct", fields = { target = { kind = "Replace", value = nil } } },
		},
	})
	expect(TestUtils.domain(fixture):GetState().target).toBeNil()
end)
