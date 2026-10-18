--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ServerTypes = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TestUtils = require(script.Parent.Parent.Utils.Networking.TagsReplicationTestUtils)
local PublicationUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)

local fixture: TestUtils.Fixture
local runtime: ServerTypes.PublicationRuntime? = nil
beforeEach(function()
	fixture = TestUtils.new()
end)
afterEach(function()
	if runtime ~= nil then
		runtime:Destroy()
		runtime = nil
	end
	TestUtils.destroy(fixture)
end)

it("captures no visible entries or historical events for an Actor with only private active Tags", function()
	TestUtils.add(fixture, "Private.Refresh")
	TestUtils.add(fixture, "Private.Stack")
	TestUtils.observe(fixture)
	expect(TestUtils.snapshot(fixture)).toEqual({})
	expect(fixture.commits).toEqual({})
end)

it("captures pre-existing visible aggregate truth with finite anchors and no server definition fields", function()
	TestUtils.add(fixture, "Private.Refresh")
	TestUtils.add(fixture, "Status.Burning")
	TestUtils.add(fixture, "Buff.Stack", 2)
	TestUtils.add(fixture, "Buff.Stack", 8)
	TestUtils.add(fixture, "Status.Permanent")
	local publication: ServerTypes.PublicationRuntime = PublicationUtils.createRuntime({ fixture.definition })
	runtime = publication
	local attached: boolean, reason: string? = publication:AttachActor(fixture.actor)
	expect(reason).toBeNil()
	expect(attached).toBe(true)
	expect(publication:CaptureBaseline(fixture.actor)).toEqual({
		sequence = 0,
		domains = {
			["KRF.Tags"] = {
				value = {
					["Status.Burning"] = { stackCount = 1, expiresAt = 1010 },
					["Buff.Stack"] = { stackCount = 2, expiresAt = 1008 },
					["Status.Permanent"] = { stackCount = 1 },
				},
			},
		},
	})
end)

it("uses the authoritative longest finite duration even when a stack also contains an indefinite instance", function()
	TestUtils.add(fixture, "Buff.Stack")
	TestUtils.add(fixture, "Buff.Stack", 7)
	TestUtils.observe(fixture)
	expect(fixture.tags:GetActiveTags()).toEqual({ { tagId = "Buff.Stack", stackCount = 2, remainingDuration = 7 } })
	expect(TestUtils.snapshot(fixture)).toEqual({ ["Buff.Stack"] = { stackCount = 2, expiresAt = 1007 } })
	TestUtils.step(fixture, 7)
	expect(TestUtils.snapshot(fixture)).toEqual({ ["Buff.Stack"] = { stackCount = 1 } })
	expect(fixture.commits).toEqual({
		{
			events = { { id = "Expired", payload = "Buff.Stack" } },
			state = { ["Buff.Stack"] = { stackCount = 1 } },
		},
	})
end)

it("fails missing-controller attachment observably and leaves no invented baseline or attachment", function()
	local actor: ActorTypes.Actor = ActorEntity.new()
	local publication: ServerTypes.PublicationRuntime = PublicationUtils.createRuntime({ fixture.definition })
	runtime = publication
	local attached: boolean, reason: string? = publication:AttachActor(actor)
	expect(attached).toBe(false)
	expect(reason).toBe("PublicationSnapshotError:KRF.Tags")
	expect(publication:CaptureBaseline(actor)).toBeNil()
	expect(publication:GetAttachedActors()).toEqual({})
end)

it("rebuilds current truth after detach without retaining stale projection state or duplicate observers", function()
	TestUtils.add(fixture, "Status.Burning")
	local disconnect = TestUtils.observe(fixture)
	disconnect()
	disconnect()
	expect(fixture.tags:RemoveTag("Status.Burning")).toBe(true)
	TestUtils.add(fixture, "Status.Permanent")
	expect(fixture.commits).toEqual({})
	TestUtils.observe(fixture)
	expect(TestUtils.snapshot(fixture)).toEqual({ ["Status.Permanent"] = { stackCount = 1 } })
	TestUtils.add(fixture, "Status.Burning", 3)
	expect(#fixture.commits).toBe(1)
	expect(fixture.commits[1].events).toEqual({ { id = "Added", payload = "Status.Burning" } })
end)

it("unwinds the Tag observer when a later domain fails attachment and retries without retaining stale state", function()
	local invalid: PublicationUtils.DomainFixture = PublicationUtils.createDomain("ZGame.Invalid", Schema.U8, 256)
	local publication: ServerTypes.PublicationRuntime =
		PublicationUtils.createRuntime({ fixture.definition, invalid.definition })
	runtime = publication
	local commits: { ServerTypes.PublicationCommit } = {}
	publication:ObserveCommits(function(commit: ServerTypes.PublicationCommit)
		table.insert(commits, commit)
	end)
	local attached: boolean, reason: string? = publication:AttachActor(fixture.actor)
	expect(attached).toBe(false)
	expect(reason).toBe("InvalidPublicationSnapshot:ZGame.Invalid")
	TestUtils.add(fixture, "Status.Burning")
	expect(commits).toEqual({})
	expect(publication:CaptureBaseline(fixture.actor)).toBeNil()
	invalid.value = 1
	local retried: boolean, retryReason: string? = publication:AttachActor(fixture.actor)
	expect(retryReason).toBeNil()
	expect(retried).toBe(true)
	expect(publication:CaptureBaseline(fixture.actor)).toEqual({
		sequence = 0,
		domains = {
			["KRF.Tags"] = { value = { ["Status.Burning"] = { stackCount = 1, expiresAt = 1010 } } },
			["ZGame.Invalid"] = { value = 1 },
		},
	})
	TestUtils.add(fixture, "Status.Burning", 3)
	expect(#commits).toBe(1)
	expect(commits[1].events).toEqual({ { domainId = "KRF.Tags", eventId = "Refreshed", payload = "Status.Burning" } })
end)
