--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Actor.types)
local SignalTypes = require(KRF.shared.Signal.types)
local GoodSignal: any = require(KRF.shared.Signal.GoodSignal)
local TestUtils = require(script.Parent.Utils.TagsViewTestUtils)

local fixture: TestUtils.Fixture
local originalFire: any = GoodSignal.Fire
local originalConnect: any = GoodSignal.Connect

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	GoodSignal.Fire = originalFire
	GoodSignal.Connect = originalConnect
	TestUtils.destroy(fixture)
end)

for _, eventId: string in { "Added", "Refreshed", "Removed", "Expired" } do
	it(
		"forwards " .. eventId .. " as exactly one semantic tagId argument with current truth already installed",
		function()
			local received: { any } = {}
			local event: SignalTypes.Event<string> = (fixture.view :: any)["OnTag" .. eventId]

			event:Connect(function(...: any)
				table.insert(received, { args = table.pack(...), current = fixture.view:GetActiveTags() })
			end)

			fixture.domain:InstallState(TestUtils.freeze({ ["Status.Other"] = { stackCount = 2 } }))
			fixture.domain:FireEvent(eventId, "Status.Subject")

			expect(received).toEqual({
				{ args = table.pack("Status.Subject"), current = { { tagId = "Status.Other", stackCount = 2 } } },
			})
		end
	)
end

for _, source: Types.DomainChangeSource in { "Commit", "Baseline" } do
	it("forwards OnStateChanged with only the " .. source .. " source and reconciled current state", function()
		local changes: { any } = {}
		local semantic: number = 0

		fixture.view.OnStateChanged:Connect(function(...: any)
			table.insert(changes, { args = table.pack(...), current = fixture.view:GetActiveTags() })
		end)

		for _, name: string in { "OnTagAdded", "OnTagRefreshed", "OnTagRemoved", "OnTagExpired" } do
			local event: SignalTypes.Event<string> = (fixture.view :: any)[name]

			event:Connect(function()
				semantic += 1
			end)
		end

		TestUtils.install(fixture, { ["Status.A"] = { stackCount = 1 } }, source)
		expect(changes).toEqual({ { args = table.pack(source), current = { { tagId = "Status.A", stackCount = 1 } } } })
		expect(semantic).toBe(0)
	end)
end

it("does not fabricate initial state-change or lifecycle history while binding an already populated domain", function()
	TestUtils.destroy(fixture)
	local fires: { any } = {}

	GoodSignal.Fire = function(self: any, ...: any)
		table.insert(fires, table.pack(...))
		originalFire(self, ...)
	end

	fixture = TestUtils.new({ ["Status.A"] = { stackCount = 1 } })
	expect(fires).toEqual({})
	expect(fixture.view:GetActiveTags()).toEqual({ { tagId = "Status.A", stackCount = 1 } })
end)

it("forwards event-only refresh occurrences without OnStateChanged or an invented Ticked event", function()
	local refreshed: { string } = {}
	local changes: number = 0

	fixture.view.OnTagRefreshed:Connect(function(tagId: string)
		table.insert(refreshed, tagId)
	end)

	fixture.view.OnStateChanged:Connect(function()
		changes += 1
	end)

	fixture.domain:FireEvent("Refreshed", "Status.A")
	fixture.domain:FireEvent("Refreshed", "Status.A")
	expect(refreshed).toEqual({ "Status.A", "Status.A" })
	expect(changes).toBe(0)
	expect((fixture.view :: any).OnTagTicked).toBeNil()
end)

it("preserves semantic Fire invocation order and sees installed truth before any typed event Fire", function()
	-- Discover each Signal receiver at its ordinary Connect boundary. This works
	-- for direct domain Events and for owned typed Signals, without exposing an
	-- owning Signal through the public Event or relying on handler completion order.
	local namesBySignal: { [any]: string } = {}
	local listeningFor: string? = nil

	GoodSignal.Connect = function(self: any, callback: any): any
		if listeningFor ~= nil then
			namesBySignal[self] = listeningFor
		end

		return originalConnect(self, callback)
	end

	for _, eventId: string in { "Added", "Refreshed", "Removed", "Expired" } do
		listeningFor = eventId
		local event: SignalTypes.Event<string> = (fixture.view :: any)["OnTag" .. eventId]
		event:Connect(function() end)
	end

	listeningFor = nil
	GoodSignal.Connect = originalConnect

	local fires: { any } = {}

	GoodSignal.Fire = function(self: any, ...: any)
		local name: string? = namesBySignal[self]

		if name ~= nil then
			table.insert(fires, { event = name, args = table.pack(...), current = fixture.view:GetActiveTags() })
		end

		originalFire(self, ...)
	end

	fixture.domain:InstallState(TestUtils.freeze({ ["Status.Final"] = { stackCount = 2 } }))
	fixture.domain:FireEvent("Added", "Status.A")
	fixture.domain:FireEvent("Refreshed", "Status.A")
	fixture.domain:FireEvent("Removed", "Status.B")
	fixture.domain:FireEvent("Expired", "Status.C")

	expect(fires).toEqual({
		{ event = "Added", args = table.pack("Status.A"), current = { { tagId = "Status.Final", stackCount = 2 } } },
		{
			event = "Refreshed",
			args = table.pack("Status.A"),
			current = { { tagId = "Status.Final", stackCount = 2 } },
		},
		{ event = "Removed", args = table.pack("Status.B"), current = { { tagId = "Status.Final", stackCount = 2 } } },
		{ event = "Expired", args = table.pack("Status.C"), current = { { tagId = "Status.Final", stackCount = 2 } } },
	})
end)

it("makes stale subscriptions unusable after the owning facade and domain are torn down", function()
	local calls: number = 0

	fixture.view.OnTagAdded:Connect(function()
		calls += 1
	end)

	fixture.domain:FireEvent("Added", "Status.A")
	expect(calls).toBe(1)
	fixture.owner:Destroy()
	fixture.domain:Destroy()
	fixture.owner:Destroy()
	fixture.domain:Destroy()
	fixture.domain:FireEvent("Added", "Status.B")
	expect(calls).toBe(1)
	expect(fixture.view:GetActiveTags()).toEqual({})

	for _, name: string in { "OnTagAdded", "OnTagRefreshed", "OnTagRemoved", "OnTagExpired", "OnStateChanged" } do
		local connected: boolean = pcall(function()
			(fixture.view :: any)[name]:Connect(function() end)
		end)

		expect(connected).toBe(false)
	end
end)
