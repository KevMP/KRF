--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Actor.types)
local Tags: Types.TagsViewModule = require(KRF.client.Actor.TagsView)
local TestUtils = require(script.Parent.Utils.TagsViewTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new({
		["Status.Z"] = { stackCount = 2, expiresAt = 1008 },
		["Buff.A"] = { stackCount = 1 },
		["Status.B"] = { stackCount = 3, expiresAt = 1005 },
	})
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("reports authoritative presence and absence without accepting private or unknown ids", function()
	expect(fixture.view:HasTag("Status.Z")).toBe(true)
	expect(fixture.view:HasTag("Buff.A")).toBe(true)
	expect(fixture.view:HasTag("Status.Unknown")).toBe(false)
	expect(fixture.view:HasTag("Private.Secret")).toBe(false)
	expect(fixture.view:GetTag("Status.Unknown")).toBeNil()
	expect(fixture.view:GetTag("Private.Secret")).toBeNil()
end)

it("returns only the semantic id, authoritative stacks and locally derived duration for an active Tag", function()
	expect(fixture.view:GetTag("Status.Z")).toEqual({ tagId = "Status.Z", stackCount = 2, remainingDuration = 8 })
	expect(fixture.view:GetTag("Buff.A")).toEqual({ tagId = "Buff.A", stackCount = 1 })
end)

it("derives a new point-in-time snapshot on each query while prior snapshots remain unchanged", function()
	local first: Types.ActiveTagSnapshot? = fixture.view:GetTag("Status.Z")
	expect(first).toEqual({ tagId = "Status.Z", stackCount = 2, remainingDuration = 8 })
	fixture.clock.now = 1003.25

	local later: Types.ActiveTagSnapshot? = fixture.view:GetTag("Status.Z")
	expect(later).toEqual({ tagId = "Status.Z", stackCount = 2, remainingDuration = 4.75 })
	expect(later).never.toBe(first)
	expect(first).toEqual({ tagId = "Status.Z", stackCount = 2, remainingDuration = 8 })
	expect(fixture.domain.view:GetState()["Status.Z"]).toEqual({ stackCount = 2, expiresAt = 1008 })
end)

it("clamps at zero without local removal, stack changes or fabricated expiry notifications", function()
	local expired: { string } = {}

	fixture.view.OnTagExpired:Connect(function(tagId: string)
		table.insert(expired, tagId)
	end)

	fixture.clock.now = 1008
	expect(fixture.view:GetTag("Status.Z")).toEqual({ tagId = "Status.Z", stackCount = 2, remainingDuration = 0 })
	fixture.clock.now = 5000
	expect(fixture.view:HasTag("Status.Z")).toBe(true)
	expect(fixture.view:GetTag("Status.Z")).toEqual({ tagId = "Status.Z", stackCount = 2, remainingDuration = 0 })
	expect(expired).toEqual({})
	TestUtils.install(fixture, {}, "Commit")
	fixture.domain:FireEvent("Expired", "Status.Z")
	expect(fixture.view:HasTag("Status.Z")).toBe(false)
	expect(fixture.view:GetTag("Status.Z")).toBeNil()
	expect(expired).toEqual({ "Status.Z" })
end)

it("returns every active id once in sorted semantic order with frozen collection and entries", function()
	local snapshots: { Types.ActiveTagSnapshot } = fixture.view:GetActiveTags()

	expect(snapshots).toEqual({
		{ tagId = "Buff.A", stackCount = 1 },
		{ tagId = "Status.B", stackCount = 3, remainingDuration = 5 },
		{ tagId = "Status.Z", stackCount = 2, remainingDuration = 8 },
	})

	expect(table.isfrozen(snapshots)).toBe(true)

	for _, snapshot: Types.ActiveTagSnapshot in snapshots do
		expect(table.isfrozen(snapshot)).toBe(true)
	end

	local changed: boolean = pcall(function()
		(snapshots :: any)[1] = { tagId = "Corrupted", stackCount = 99 }
	end)

	expect(changed).toBe(false)

	local entryChanged: boolean = pcall(function()
		(snapshots[1] :: any).stackCount = 99
	end)

	expect(entryChanged).toBe(false)
	expect(fixture.view:GetTag("Buff.A")).toEqual({ tagId = "Buff.A", stackCount = 1 })
end)

it("prevents mutation of GetTag snapshots and keeps them detached from future domain truth", function()
	local snapshot: Types.ActiveTagSnapshot? = fixture.view:GetTag("Status.Z")
	expect(snapshot).toEqual({ tagId = "Status.Z", stackCount = 2, remainingDuration = 8 })
	assert(snapshot ~= nil, "Expected active snapshot")
	expect(table.isfrozen(snapshot)).toBe(true)

	local changed: boolean = pcall(function()
		(snapshot :: any).remainingDuration = 999
	end)

	expect(changed).toBe(false)
	TestUtils.install(fixture, { ["Status.Z"] = { stackCount = 1, expiresAt = 1002 } }, "Baseline")
	expect(fixture.view:GetTag("Status.Z")).toEqual({ tagId = "Status.Z", stackCount = 1, remainingDuration = 2 })
	expect(snapshot).toEqual({ tagId = "Status.Z", stackCount = 2, remainingDuration = 8 })
end)

it("reads current DomainView truth after installation without waiting for change callbacks", function()
	fixture.domain:InstallState(TestUtils.freeze({ ["Status.Z"] = { stackCount = 7, expiresAt = 1001 } }))
	expect(fixture.view:GetTag("Status.Z")).toEqual({ tagId = "Status.Z", stackCount = 7, remainingDuration = 1 })
	expect(fixture.view:HasTag("Buff.A")).toBe(false)
	expect(fixture.view:GetActiveTags()).toEqual({ { tagId = "Status.Z", stackCount = 7, remainingDuration = 1 } })
end)

it("returns an immutable empty view when the server omits KRF.Tags without reading a countdown clock", function()
	local empty: Types.TagsViewOwner = Tags.new(function(): Types.DomainView?
		return nil
	end, function(): number
		error("AnEmptyViewHasNoCountdownToDerive")
	end)

	local success: boolean, reason: any = pcall(function()
		expect(table.isfrozen(empty.view)).toBe(true)
		expect(empty.view:HasTag("Status.Z")).toBe(false)
		expect(empty.view:GetTag("Status.Z")).toBeNil()
		expect(empty.view:GetActiveTags()).toEqual({})
		expect(table.isfrozen(empty.view:GetActiveTags())).toBe(true)
	end)

	empty:Destroy()
	expect(reason).toBeNil()
	expect(success).toBe(true)
end)

it("exposes no client mutation, timing anchor, controller, installation or writable Signal surface", function()
	expect(table.isfrozen(fixture.view)).toBe(true)

	for _, member: string in
		{
			"AddTag",
			"RemoveTag",
			"RemoveSingleTag",
			"RefreshTag",
			"SetStacks",
			"InstallState",
			"Destroy",
			"expiresAt",
			"controller",
		}
	do
		expect((fixture.view :: any)[member]).toBeNil()
	end

	for _, member: string in { "OnTagAdded", "OnTagRefreshed", "OnTagRemoved", "OnTagExpired", "OnStateChanged" } do
		local readable: boolean = pcall(function()
			return (fixture.view :: any)[member].Fire
		end)

		expect(readable).toBe(false)
	end

	local changed: boolean = pcall(function()
		(fixture.view :: any).HasTag = function(): boolean
			return true
		end
	end)

	expect(changed).toBe(false)
end)
