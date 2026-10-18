--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Actor.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ClientTypes = require(KRF.client.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local GoodSignal: any = require(KRF.shared.Signal.GoodSignal)
local TagsView: Types.TagsViewModule = require(KRF.client.Actor.TagsView)
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)
local StreamUtils = require(script.Parent.Utils.ActorStreamTestUtils)
local TagsUtils = require(script.Parent.Utils.TagsViewTestUtils)

local fixture: TestUtils.Fixture
local originalFire: any = GoodSignal.Fire
local originalConnect: any = GoodSignal.Connect
local originalTagsNew: typeof(TagsView.new) = TagsView.new
beforeEach(function()
	local tagId: SharedTypes.SchemaDefinition = Schema.Enum({ "Status.A", "Status.B", "Status.C" })
	fixture = TestUtils.new(nil, {
		version = Constants.PROTOCOL_VERSION,
		domains = {
			{ id = "Game.Counter", code = 0, state = Schema.U8, events = {} },
			{
				id = "KRF.Tags",
				code = 1,
				state = Schema.Map(
					tagId,
					Schema.Struct({ stackCount = Schema.U32, expiresAt = Schema.Optional(Schema.F64) }),
					3
				),
				events = {
					{ id = "Added", code = 0, payload = tagId },
					{ id = "Expired", code = 1, payload = tagId },
					{ id = "Refreshed", code = 2, payload = tagId },
					{ id = "Removed", code = 3, payload = tagId },
				},
			},
		},
	})
end)
afterEach(function()
	TagsView.new = originalTagsNew
	GoodSignal.Fire = originalFire
	GoodSignal.Connect = originalConnect
	TestUtils.destroy(fixture)
end)

local function truth(tags: TagsUtils.WireState): { [string]: SharedTypes.ActorDomainTruth }
	return { ["Game.Counter"] = { value = 1 }, ["KRF.Tags"] = { value = tags } }
end

local function baseline(): Types.ActorView
	TestUtils.baseline(fixture, nil, nil, nil, truth({ ["Status.A"] = { stackCount = 1 } }))
	return TestUtils.view(fixture)
end

it("constructs a stable read-only TagsView from an ordinary encoded N4 baseline with no lifecycle replay", function()
	local semanticFires: { any } = {}
	GoodSignal.Fire = function(self: any, ...: any)
		local first: any = ...
		if type(first) == "string" then
			table.insert(semanticFires, table.pack(...))
		end
		originalFire(self, ...)
	end
	local view: Types.ActorView = baseline()
	local tags: Types.TagsView = view:GetTags()
	expect(view:GetTags()).toBe(tags)
	expect(table.isfrozen(tags)).toBe(true)
	expect(tags:GetActiveTags()).toEqual({ { tagId = "Status.A", stackCount = 1 } })
	expect(TestUtils.domain(fixture, "KRF.Tags"):GetState()).toEqual({ ["Status.A"] = { stackCount = 1 } })
	expect(semanticFires).toEqual({})
end)

it("supplies each typed facade with its own current N5 domain and revokes that source on Actor teardown", function()
	local sources: { () -> Types.DomainView? } = {}
	TagsView.new = function(getDomain: () -> Types.DomainView?, serverTimeNow: (() -> number)?): Types.TagsViewOwner
		table.insert(sources, getDomain)
		return originalTagsNew(getDomain, serverTimeNow)
	end
	local first: Types.ActorView = baseline()
	TestUtils.baseline(fixture, 2, "ActorB", 0, truth({ ["Status.B"] = { stackCount = 2 } }))
	local second: Types.ActorView = TestUtils.view(fixture, "ActorB")
	expect(#sources).toBe(2)
	expect(sources[1]()).toBe(first:GetDomain("KRF.Tags"))
	expect(sources[2]()).toBe(second:GetDomain("KRF.Tags"))
	expect(sources[1]()).never.toBe(sources[2]())
	TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })
	expect(sources[1]()).toBeNil()
	expect(sources[2]()).toBe(second:GetDomain("KRF.Tags"))
	fixture.runtime:Destroy()
	expect(sources[1]()).toBeNil()
	expect(sources[2]()).toBeNil()
end)

it("keeps an empty stable facade when bootstrap has no Tags domain", function()
	TestUtils.destroy(fixture)
	fixture = TestUtils.new(nil, { version = Constants.PROTOCOL_VERSION, domains = {} })
	TestUtils.baseline(fixture, nil, nil, nil, {})
	local view: Types.ActorView = TestUtils.view(fixture)
	local tags: Types.TagsView = view:GetTags()
	expect(view:GetDomain("KRF.Tags")).toBeNil()
	expect(view:GetTags()).toBe(tags)
	expect(tags:GetActiveTags()).toEqual({})
	expect(tags:HasTag("Status.A")).toBe(false)
	expect(tags:GetTag("Status.A")).toBeNil()
	TestUtils.baseline(fixture, 1, nil, 50, {}, 2)
	expect(view:GetTags()).toBe(tags)
	expect(tags:GetActiveTags()).toEqual({})
end)

it("reconciles changed replacement truth without changing facade identity or inventing semantic history", function()
	local view: Types.ActorView = baseline()
	local tags: Types.TagsView = view:GetTags()
	local sources: { Types.DomainChangeSource } = {}
	local events: { string } = {}
	tags.OnStateChanged:Connect(function(source: Types.DomainChangeSource)
		table.insert(sources, source)
	end)
	for _, name: string in { "OnTagAdded", "OnTagRefreshed", "OnTagRemoved", "OnTagExpired" } do
		local event: SignalTypes.Event<string> = (tags :: any)[name]
		event:Connect(function(tagId: string)
			table.insert(events, tagId)
		end)
	end
	TestUtils.baseline(fixture, 1, nil, 50, truth({ ["Status.B"] = { stackCount = 3 } }), 2)
	expect(TestUtils.view(fixture)).toBe(view)
	expect(view:GetTags()).toBe(tags)
	expect(tags:GetActiveTags()).toEqual({ { tagId = "Status.B", stackCount = 3 } })
	expect(sources).toEqual({ "Baseline" })
	expect(events).toEqual({})
	TestUtils.commit(fixture, 51, {}, { { domainId = "KRF.Tags", eventId = "Refreshed", payload = "Status.B" } })
	expect(events).toEqual({ "Status.B" })
	expect(sources).toEqual({ "Baseline" })
	TestUtils.baseline(fixture, 1, nil, 60, truth({ ["Status.B"] = { stackCount = 3 } }), 3)
	expect(sources).toEqual({ "Baseline" })
end)

it(
	"installs every domain before typed semantic Fire and preserves same-flush occurrence order across commits",
	function()
		local view: Types.ActorView = baseline()
		local tags: Types.TagsView = view:GetTags()
		local names: { [any]: string } = {}
		local connecting: string? = nil
		GoodSignal.Connect = function(self: any, callback: any): any
			if connecting ~= nil then
				names[self] = connecting
			end
			return originalConnect(self, callback)
		end
		for _, id: string in { "Added", "Removed", "Refreshed" } do
			connecting = id
			local event: SignalTypes.Event<string> = (tags :: any)["OnTag" .. id]
			event:Connect(function() end)
		end
		GoodSignal.Connect = originalConnect
		local fires: { any } = {}
		GoodSignal.Fire = function(self: any, ...: any)
			if names[self] ~= nil then
				table.insert(fires, {
					event = names[self],
					args = table.pack(...),
					tags = tags:GetActiveTags(),
					counter = TestUtils.domain(fixture, "Game.Counter"):GetState(),
				})
			end
			originalFire(self, ...)
		end
		TestUtils.send(fixture, {
			{
				kind = "Commit",
				handle = 1,
				revision = 11,
				patches = {
					{ domainId = "Game.Counter", patch = { kind = "Replace", value = 2 } },
					{
						domainId = "KRF.Tags",
						patch = {
							kind = "Map",
							entries = { ["Status.B"] = { stackCount = 3 } },
							removed = { "Status.A" },
						},
					},
				},
				events = {
					{ domainId = "KRF.Tags", eventId = "Removed", payload = "Status.A" },
					{ domainId = "KRF.Tags", eventId = "Added", payload = "Status.B" },
				},
			},
			{
				kind = "Commit",
				handle = 1,
				revision = 12,
				patches = {},
				events = { { domainId = "KRF.Tags", eventId = "Refreshed", payload = "Status.B" } },
			},
		})
		expect(fires).toEqual({
			{
				event = "Removed",
				args = table.pack("Status.A"),
				tags = { { tagId = "Status.B", stackCount = 3 } },
				counter = 2,
			},
			{
				event = "Added",
				args = table.pack("Status.B"),
				tags = { { tagId = "Status.B", stackCount = 3 } },
				counter = 2,
			},
			{
				event = "Refreshed",
				args = table.pack("Status.B"),
				tags = { { tagId = "Status.B", stackCount = 3 } },
				counter = 2,
			},
		})
	end
)

it("keeps TagsView truth and subscriptions alive through Model stream-out and stream-in", function()
	local view: Types.ActorView = baseline()
	local tags: Types.TagsView = view:GetTags()
	local refreshed: { string } = {}
	tags.OnTagRefreshed:Connect(function(tagId: string)
		table.insert(refreshed, tagId)
	end)
	local candidate: ClientTypes.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorA")
	StreamUtils.add(fixture.stream, candidate)
	expect(view:GetModel()).toBe(candidate.model)
	StreamUtils.remove(fixture.stream, candidate)
	expect(view:GetModel()).toBeNil()
	expect(view:GetTags()).toBe(tags)
	expect(tags:GetActiveTags()).toEqual({ { tagId = "Status.A", stackCount = 1 } })
	StreamUtils.add(fixture.stream, candidate)
	TestUtils.commit(fixture, 11, {}, { { domainId = "KRF.Tags", eventId = "Refreshed", payload = "Status.A" } })
	expect(refreshed).toEqual({ "Status.A" })
end)

it("retires TagsView state and subscriptions on Actor removal without rebinding stale references to respawn", function()
	local view: Types.ActorView = baseline()
	local tags: Types.TagsView = view:GetTags()
	local received: { string } = {}
	tags.OnTagAdded:Connect(function(tagId: string)
		table.insert(received, tagId)
	end)
	expect(tags:HasTag("Status.A")).toBe(true)
	TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })
	expect(fixture.runtime.registry.GetActorViewById("ActorA")).toBeNil()
	expect(tags:GetActiveTags()).toEqual({})
	expect(tags:GetTag("Status.A")).toBeNil()
	local connected: boolean = pcall(function()
		tags.OnTagAdded:Connect(function() end)
	end)
	expect(connected).toBe(false)
	TestUtils.baseline(fixture, 2, "ActorRespawn", 0, truth({ ["Status.B"] = { stackCount = 2 } }))
	local respawn: Types.ActorView = TestUtils.view(fixture, "ActorRespawn")
	expect(respawn:GetTags()).never.toBe(tags)
	expect(respawn:GetTags():GetActiveTags()).toEqual({ { tagId = "Status.B", stackCount = 2 } })
	TestUtils.commit(fixture, 1, {}, { { domainId = "KRF.Tags", eventId = "Added", payload = "Status.B" } }, 2)
	expect(received).toEqual({})
	expect(tags:GetActiveTags()).toEqual({})
end)

it("clears typed truth when N5 halts while retaining ActorView identity", function()
	local view: Types.ActorView = baseline()
	local tags: Types.TagsView = view:GetTags()
	expect(tags:HasTag("Status.A")).toBe(true)
	fixture.runtime.consumer.OnActorHalted(TestUtils.actor(fixture))
	expect(TestUtils.view(fixture)).toBe(view)
	expect(view:IsAvailable()).toBe(false)
	expect(view:GetTags()).toBe(tags)
	expect(tags:GetActiveTags()).toEqual({})
	expect(tags:HasTag("Status.A")).toBe(false)
end)

for _, invalidPart: string in { "state", "event" } do
	it(
		"rejects a private id in decoded " .. invalidPart .. " atomically before generic or typed publication",
		function()
			local view: Types.ActorView = baseline()
			local tags: Types.TagsView = view:GetTags()
			local previous: any = TestUtils.domain(fixture, "KRF.Tags"):GetState()
			local events: number = 0
			tags.OnTagAdded:Connect(function()
				events += 1
			end)
			fixture.runtime.consumer.OnCommitReady(TestUtils.actor(fixture), 11, {
				{ domainId = "Game.Counter", patch = { kind = "Replace", value = 2 } },
				{
					domainId = "KRF.Tags",
					patch = {
						kind = "Map",
						entries = {
							[if invalidPart == "state" then "Private.Secret" else "Status.B"] = { stackCount = 1 },
						},
						removed = {},
					},
				},
			}, {
				{
					domainId = "KRF.Tags",
					eventId = "Added",
					payload = if invalidPart == "event" then "Private.Secret" else "Status.B",
				},
			})
			expect(TestUtils.domain(fixture, "KRF.Tags"):GetState()).toBe(previous)
			expect(TestUtils.domain(fixture, "Game.Counter"):GetState()).toBe(1)
			expect(tags:GetActiveTags()).toEqual({ { tagId = "Status.A", stackCount = 1 } })
			expect(tags:GetTag("Private.Secret")).toBeNil()
			expect(events).toBe(0)
			expect(#fixture.requests).toBe(1)
			expect(#fixture.faults).toBe(1)
		end
	)
end
