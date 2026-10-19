--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Actor.types)
local ClientTypes = require(KRF.client.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Resources: Types.ResourcesViewModule = require(KRF.client.Actor.ResourcesView)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local GoodSignal: any = require(KRF.shared.Signal.GoodSignal)
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)
local StreamUtils = require(script.Parent.Utils.ActorStreamTestUtils)
local ResourceUtils = require(script.Parent.Utils.ResourcesViewTestUtils)

local fixture: TestUtils.Fixture
local now: number = 1000
local originalNew = Resources.new
local originalConnect: any = GoodSignal.Connect
local originalFire: any = GoodSignal.Fire

beforeEach(function()
	now = 1000

	Resources.new = function(
		getDomain: () -> Types.DomainView?,
		_serverTimeNow: (() -> number)?
	): Types.ResourcesViewOwner
		return originalNew(getDomain, function(): number
			return now
		end)
	end

	fixture = TestUtils.new(nil, {
		version = Constants.PROTOCOL_VERSION,
		domains = {
			{
				id = "Game.Actions",
				code = 0,
				state = Schema.U8,
				events = { { id = "Started", code = 0, payload = Schema.U8 } },
			},
			{
				id = "KRF.Resources",
				code = 1,
				state = Schema.Map(
					Schema.Enum({ "Resource.Mana", "Resource.Stamina" }),
					Schema.Struct({
						anchorValue = Schema.F64,
						anchorTime = Schema.F64,
						min = Schema.F64,
						max = Schema.F64,
						regenRate = Schema.Optional(Schema.F64),
					}),
					2
				),
				events = {},
			},
		},
	})
end)

afterEach(function()
	Resources.new = originalNew
	GoodSignal.Connect = originalConnect
	GoodSignal.Fire = originalFire
	TestUtils.destroy(fixture)
end)

local function truth(mana: number?, stamina: number?): { [string]: SharedTypes.ActorDomainTruth }
	return {
		["Game.Actions"] = { value = 0 },
		["KRF.Resources"] = {
			value = {
				["Resource.Mana"] = { anchorValue = mana or 40, anchorTime = 1000, min = 0, max = 100, regenRate = 10 },
				["Resource.Stamina"] = {
					anchorValue = stamina or 20,
					anchorTime = 1000,
					min = 0,
					max = 100,
					regenRate = 5,
				},
			},
		},
	}
end

local function baseline(): Types.ActorView
	TestUtils.baseline(fixture, nil, nil, nil, truth())

	return TestUtils.view(fixture)
end

local function manaPatch(value: number): SharedTypes.ActorDomainPatch
	return {
		domainId = "KRF.Resources",
		patch = {
			kind = "Map",
			entries = {
				["Resource.Mana"] = { anchorValue = value, anchorTime = 1000, min = 0, max = 100, regenRate = 10 },
			},
			removed = {},
		},
	}
end

it("constructs one stable ResourcesView over an ordinary encoded baseline and exposes the same N5 truth", function()
	local view: Types.ActorView = baseline()
	local resources: Types.ResourcesView = view:GetResources()
	expect(view:GetResources()).toBe(resources)
	expect(table.isfrozen(resources)).toBe(true)
	expect(resources:GetCurrent("Resource.Mana")).toBe(40)
	expect(TestUtils.domain(fixture, "KRF.Resources"):GetState()).toEqual(truth()["KRF.Resources"].value)
	expect(resources:HasResource("Private.Secret")).toBe(false)
end)

it("binds each facade to its own current DomainView and revokes that source on teardown", function()
	local sources: { () -> Types.DomainView? } = {}

	Resources.new = function(
		getDomain: () -> Types.DomainView?,
		serverTimeNow: (() -> number)?
	): Types.ResourcesViewOwner
		table.insert(sources, getDomain)

		return originalNew(getDomain, serverTimeNow)
	end

	local first: Types.ActorView = baseline()
	TestUtils.baseline(fixture, 2, "ActorB", 0, truth(30))
	local second: Types.ActorView = TestUtils.view(fixture, "ActorB")
	expect(#sources).toBe(2)
	expect(sources[1]()).toBe(first:GetDomain("KRF.Resources"))
	expect(sources[2]()).toBe(second:GetDomain("KRF.Resources"))
	TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })
	expect(sources[1]()).toBeNil()
	expect(sources[2]()).toBe(second:GetDomain("KRF.Resources"))
	fixture.runtime:Destroy()
	expect(sources[2]()).toBeNil()
end)

it("provides the same empty ResourcesView across replacement baselines when bootstrap omits the domain", function()
	TestUtils.destroy(fixture)
	fixture = TestUtils.new(nil, { version = Constants.PROTOCOL_VERSION, domains = {} })
	TestUtils.baseline(fixture, nil, nil, nil, {})
	local view: Types.ActorView = TestUtils.view(fixture)
	local resources: Types.ResourcesView = view:GetResources()
	expect(view:GetDomain("KRF.Resources")).toBeNil()
	expect(resources:GetAssignedResources()).toEqual({})
	expect(resources:HasResource("Resource.Mana")).toBe(false)
	TestUtils.baseline(fixture, 1, nil, 50, {}, 2)
	expect(view:GetResources()).toBe(resources)
	expect(resources:GetAssignedResources()).toEqual({})
end)

it("recovers a revision gap through N5 replacement without replacing Resource identity or subscriptions", function()
	local view: Types.ActorView = baseline()
	local resources: Types.ResourcesView = view:GetResources()
	local changes: { Types.ResourceViewChange } = {}

	resources.OnResourceChanged:Connect(function(change: Types.ResourceViewChange)
		table.insert(changes, change)
	end)

	TestUtils.commit(fixture, 12)
	expect(#fixture.requests).toBe(1)
	TestUtils.baseline(fixture, 1, nil, 50, truth(25), 2)
	expect(TestUtils.view(fixture)).toBe(view)
	expect(view:GetResources()).toBe(resources)
	expect(resources:GetCurrent("Resource.Mana")).toBe(25)
	expect(#changes).toBe(1)
	expect(changes[1].source).toBe("Baseline")
	TestUtils.commit(fixture, 51, { manaPatch(20) })
	expect(#changes).toBe(2)
	expect(changes[2].source).toBe("Commit")
	expect(resources:GetCurrent("Resource.Mana")).toBe(20)
end)

it("ignores unchanged replacement entries even when client time has advanced", function()
	local resources: Types.ResourcesView = baseline():GetResources()
	local changes: number = 0

	resources.OnResourceChanged:Connect(function()
		changes += 1
	end)

	now = 1002
	TestUtils.baseline(fixture, 1, nil, 50, truth(), 2)
	expect(changes).toBe(0)
	expect(resources:GetCurrent("Resource.Mana")).toBe(60)
end)

it("installs all Action and Resource state before ActionStarted semantic Fire", function()
	local view: Types.ActorView = baseline()
	local resources: Types.ResourcesView = view:GetResources()
	local event: SignalTypes.Event<any>? = TestUtils.domain(fixture, "Game.Actions"):GetEvent("Started")
	assert(event ~= nil, "Expected declared game event")
	local startedSignal: any = nil

	GoodSignal.Connect = function(self: any, callback: any): any
		startedSignal = self

		return originalConnect(self, callback)
	end

	event:Connect(function() end)
	GoodSignal.Connect = originalConnect

	local atFire: { any } = {}

	GoodSignal.Fire = function(self: any, ...: any)
		if self == startedSignal then
			table.insert(atFire, {
				mana = resources:GetCurrent("Resource.Mana"),
				stamina = resources:GetCurrent("Resource.Stamina"),
				actions = TestUtils.domain(fixture, "Game.Actions"):GetState(),
			})
		end

		originalFire(self, ...)
	end

	TestUtils.commit(fixture, 11, {
		{
			domainId = "KRF.Resources",
			patch = {
				kind = "Map",
				entries = {
					["Resource.Mana"] = { anchorValue = 25, anchorTime = 1000, min = 0, max = 100, regenRate = 10 },
					["Resource.Stamina"] = { anchorValue = 15, anchorTime = 1000, min = 0, max = 100, regenRate = 5 },
				},
				removed = {},
			},
		},
		{ domainId = "Game.Actions", patch = { kind = "Replace", value = 1 } },
	}, { { domainId = "Game.Actions", eventId = "Started", payload = 1 } })

	expect(atFire).toEqual({ { mana = 25, stamina = 15, actions = 1 } })
end)

it("keeps Resource truth and subscriptions alive through Model stream-out and rebind", function()
	local view: Types.ActorView = baseline()
	local resources: Types.ResourcesView = view:GetResources()
	local changes: number = 0

	resources.OnResourceChanged:Connect(function()
		changes += 1
	end)

	local candidate: ClientTypes.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorA")
	StreamUtils.add(fixture.stream, candidate)
	StreamUtils.remove(fixture.stream, candidate)
	expect(view:GetModel()).toBeNil()
	expect(view:GetResources()).toBe(resources)
	expect(TestUtils.domain(fixture, "KRF.Resources"):GetState()).toEqual(truth()["KRF.Resources"].value)
	expect(changes).toBe(0)
	StreamUtils.add(fixture.stream, candidate)
	TestUtils.commit(fixture, 11, { manaPatch(30) })
	expect(view:GetModel()).toBe(candidate.model)
	expect(resources:GetCurrent("Resource.Mana")).toBe(30)
	expect(changes).toBe(1)
end)

it("destroys stale Resource subscriptions on Actor removal and never rebinds them to a respawn", function()
	local resources: Types.ResourcesView = baseline():GetResources()
	local changes: number = 0

	resources.OnResourceChanged:Connect(function()
		changes += 1
	end)

	TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })
	expect(resources:GetAssignedResources()).toEqual({})

	local connected: boolean = pcall(function()
		resources.OnResourceChanged:Connect(function() end)
	end)

	expect(connected).toBe(false)
	TestUtils.baseline(fixture, 2, "ActorRespawn", 0, truth(30))
	local respawn: Types.ActorView = TestUtils.view(fixture, "ActorRespawn")
	expect(respawn:GetResources()).never.toBe(resources)
	TestUtils.commit(fixture, 1, { manaPatch(20) }, nil, 2)
	expect(respawn:GetResources():GetCurrent("Resource.Mana")).toBe(20)
	expect(resources:GetAssignedResources()).toEqual({})
	expect(changes).toBe(0)
end)

it("empties the stable typed facade when N5 halts its Actor", function()
	local view: Types.ActorView = baseline()
	local resources: Types.ResourcesView = view:GetResources()
	fixture.runtime.consumer.OnActorHalted(TestUtils.actor(fixture))
	expect(TestUtils.view(fixture)).toBe(view)
	expect(view:IsAvailable()).toBe(false)
	expect(view:GetResources()).toBe(resources)
	expect(resources:GetAssignedResources()).toEqual({})
	expect(resources:GetCurrent("Resource.Mana")).toBeNil()
end)

for _, invalid: string in { "private id", "non-finite value", "missing anchor" } do
	it("rejects decoded " .. invalid .. " atomically through N5 recovery", function()
		local resources: Types.ResourcesView = baseline():GetResources()
		local previous: any = TestUtils.domain(fixture, "KRF.Resources"):GetState()
		local entry: any = { anchorValue = 30, anchorTime = 1000, min = 0, max = 100 }

		if invalid == "non-finite value" then
			entry.anchorValue = 0 / 0
		end

		if invalid == "missing anchor" then
			entry.anchorTime = nil
		end

		local changes: number = 0

		resources.OnResourceChanged:Connect(function()
			changes += 1
		end)

		fixture.runtime.consumer.OnCommitReady(TestUtils.actor(fixture), 11, {
			{ domainId = "Game.Actions", patch = { kind = "Replace", value = 1 } },
			{
				domainId = "KRF.Resources",
				patch = {
					kind = "Map",
					entries = { [if invalid == "private id" then "Private.Secret" else "Resource.Mana"] = entry },
					removed = {},
				},
			},
		}, {})

		expect(TestUtils.domain(fixture, "KRF.Resources"):GetState()).toBe(previous)
		expect(TestUtils.domain(fixture, "Game.Actions"):GetState()).toBe(0)
		expect(resources:HasResource("Private.Secret")).toBe(false)
		expect(changes).toBe(0)
		expect(#fixture.requests).toBe(1)
		expect(#fixture.faults).toBe(1)
	end)
end

it("derives smooth queries locally without requesting network state or changing the raw anchor", function()
	local resources: Types.ResourcesView = baseline():GetResources()
	local before: ResourceUtils.WireState = TestUtils.domain(fixture, "KRF.Resources"):GetState()

	for index: number = 1, 100 do
		now = 1000 + index * 0.1
		resources:GetCurrent("Resource.Mana")
		resources:GetAssignedResources()
	end

	expect(resources:GetCurrent("Resource.Mana")).toBe(100)
	expect(TestUtils.domain(fixture, "KRF.Resources"):GetState()).toBe(before)
	expect(fixture.requests).toEqual({})
	expect(fixture.faults).toEqual({})
end)
