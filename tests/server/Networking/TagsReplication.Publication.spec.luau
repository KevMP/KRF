--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ServerTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Validate = require(KRF.shared.Networking.utils.SchemaValidator)
local TestUtils = require(script.Parent.Parent.Utils.Networking.TagsReplicationTestUtils)
local PublicationUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)
local DomainUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)

local fixture: TestUtils.Fixture
local runtime: ServerTypes.PublicationRuntime? = nil
local commits: { ServerTypes.PublicationCommit } = {}
local faults: { ServerTypes.PublicationFault } = {}
beforeEach(function()
	fixture = TestUtils.new()
	commits = {}
	faults = {}
end)
afterEach(function()
	if runtime ~= nil then
		runtime:Destroy()
		runtime = nil
	end
	TestUtils.destroy(fixture)
end)

local function attach(definitions: { ReplicationTypes.ReplicationDomainDefinition }?): ServerTypes.PublicationRuntime
	local publication: ServerTypes.PublicationRuntime =
		PublicationUtils.createRuntime(definitions or { fixture.definition }, {
			ReportFault = function(fault: ServerTypes.PublicationFault)
				table.insert(faults, fault)
			end,
		})
	runtime = publication
	publication:ObserveCommits(function(commit: ServerTypes.PublicationCommit)
		table.insert(commits, commit)
	end)
	local success: boolean, reason: string? = publication:AttachActor(fixture.actor)
	expect(reason).toBeNil()
	expect(success).toBe(true)
	return publication
end

it("produces no N3 revisions for countdown or private mutations after a real visible publication", function()
	local publication: ServerTypes.PublicationRuntime = attach()
	TestUtils.add(fixture, "Status.Burning")
	expect(#commits).toBe(1)
	local previous: ServerTypes.PublicationBaseline? = publication:CaptureBaseline(fixture.actor)
	for _ = 1, 20 do
		TestUtils.step(fixture, 0.125)
		TestUtils.add(fixture, "Private.Refresh")
	end
	expect(#commits).toBe(1)
	expect(publication:GetActorSequence(fixture.actor)).toBe(1)
	expect(publication:CaptureBaseline(fixture.actor)).toEqual(previous)
	expect(faults).toEqual({})
end)

it("preserves an event-only refresh barrier through N3 with no state patch", function()
	TestUtils.add(fixture, "Buff.Stack", 2)
	TestUtils.add(fixture, "Buff.Stack", 10)
	TestUtils.add(fixture, "Buff.Stack", 8)
	local publication: ServerTypes.PublicationRuntime = attach()
	TestUtils.add(fixture, "Buff.Stack", 5)
	expect(#commits).toBe(1)
	expect(commits[1]).toEqual({
		actor = fixture.actor,
		sequence = 1,
		patches = {},
		events = { { domainId = "KRF.Tags", eventId = "Refreshed", payload = "Buff.Stack" } },
	})
	expect(publication:GetActorSequence(fixture.actor)).toBe(1)
end)

it("publishes only the touched Map entry while unrelated timed Tags retain their exact anchors", function()
	TestUtils.add(fixture, "Status.Burning")
	local publication: ServerTypes.PublicationRuntime = attach()
	TestUtils.step(fixture, 2)
	fixture.clock.now += 0.125
	TestUtils.add(fixture, "Buff.Stack", 6)
	expect(#commits).toBe(1)
	expect(commits[1].patches).toEqual({
		{
			domainId = "KRF.Tags",
			patch = {
				kind = "Map",
				entries = { ["Buff.Stack"] = { stackCount = 1, expiresAt = 1008.125 } },
				removed = {},
			},
		},
	})
	expect(publication:CaptureBaseline(fixture.actor)).toEqual({
		sequence = 1,
		domains = {
			["KRF.Tags"] = {
				value = {
					["Status.Burning"] = { stackCount = 1, expiresAt = 1010 },
					["Buff.Stack"] = { stackCount = 1, expiresAt = 1008.125 },
				},
			},
		},
	})
end)

it("joins ordinary Actor commit grouping atomically with another domain without a second transaction API", function()
	local counter: PublicationUtils.DomainFixture = PublicationUtils.createDomain("Game.Counter", Schema.U8, 1)
	local publication: ServerTypes.PublicationRuntime = attach({ fixture.definition, counter.definition })
	publication:WithActorCommit(fixture.actor, function()
		TestUtils.add(fixture, "Status.Permanent")
		counter.value = 2
		counter.callbacks[fixture.actor]()
		TestUtils.add(fixture, "Status.Burning", 6)
		expect(commits).toEqual({})
	end)
	expect(#commits).toBe(1)
	expect(commits[1].patches).toEqual({
		{ domainId = "Game.Counter", patch = { kind = "Replace", value = 2 } },
		{
			domainId = "KRF.Tags",
			patch = {
				kind = "Map",
				entries = {
					["Status.Permanent"] = { stackCount = 1 },
					["Status.Burning"] = { stackCount = 1, expiresAt = 1006 },
				},
				removed = {},
			},
		},
	})
	expect(commits[1].events).toEqual({
		{ domainId = "KRF.Tags", eventId = "Added", payload = "Status.Permanent" },
		{ domainId = "KRF.Tags", eventId = "Added", payload = "Status.Burning" },
	})
end)

for _, invalidTime: number in { math.huge, -math.huge, 0 / 0 } do
	it(
		"rejects a non-finite timing anchor atomically without advancing revision or publishing events ("
			.. tostring(invalidTime)
			.. ")",
		function()
			local counter: PublicationUtils.DomainFixture = PublicationUtils.createDomain("Game.Counter", Schema.U8, 1)
			local publication: ServerTypes.PublicationRuntime = attach({ fixture.definition, counter.definition })
			local before: ServerTypes.PublicationBaseline? = publication:CaptureBaseline(fixture.actor)
			fixture.clock.now = invalidTime
			local accepted: boolean, reason: any = pcall(function()
				publication:WithActorCommit(fixture.actor, function()
					counter.value = 2
					counter.callbacks[fixture.actor]()
					TestUtils.add(fixture, "Status.Burning")
				end)
			end)
			expect(accepted).toBe(false)
			expect(reason).toBe("InvalidPublicationSnapshot:KRF.Tags")
			expect(publication:CaptureBaseline(fixture.actor)).toEqual(before)
			expect(publication:GetActorSequence(fixture.actor)).toBe(0)
			expect(commits).toEqual({})
			expect(faults).toEqual({
				{ actorId = fixture.actor:GetId(), domainId = "KRF.Tags", reason = "InvalidPublicationSnapshot" },
			})
			fixture.clock.now = 1001
			TestUtils.add(fixture, "Status.Burning", 4)
			expect(#commits).toBe(1)
			expect(commits[1].events).toEqual({
				{ domainId = "KRF.Tags", eventId = "Refreshed", payload = "Status.Burning" },
			})
		end
	)
end

it("accepts the U32 stack boundary and rejects overflow, negative, fractional and non-finite stacks", function()
	local catalog: ReplicationTypes.PreparedReplicationDomainCatalog = DomainUtils.prepare({ fixture.definition })
	local schema: SharedTypes.CompiledSchema = catalog.orderedDefinitions[1].state
	for _, count: number in { 0, 1, 4294967295 } do
		local valid: boolean, reason: string? = Validate.Validate(schema, { ["Buff.Stack"] = { stackCount = count } })
		expect(reason).toBeNil()
		expect(valid).toBe(true)
	end
	for _, case: { count: number, reason: string } in
		{
			{ count = -1, reason = "SchemaIntegerOutOfRange" },
			{ count = 1.5, reason = "SchemaIntegerMustBeIntegral" },
			{ count = 4294967296, reason = "SchemaIntegerOutOfRange" },
			{ count = math.huge, reason = "SchemaNumberMustBeFinite" },
			{ count = 0 / 0, reason = "SchemaNumberMustBeFinite" },
		}
	do
		local valid: boolean, reason: string? =
			Validate.Validate(schema, { ["Buff.Stack"] = { stackCount = case.count } })
		expect(valid).toBe(false)
		expect(reason).toBe(case.reason)
	end
end)

it("rejects private ids in both state and event schema instead of accepting them as client-visible values", function()
	local catalog: ReplicationTypes.PreparedReplicationDomainCatalog = DomainUtils.prepare({ fixture.definition })
	local domain: ReplicationTypes.LoadedReplicationDomainDefinition = catalog.orderedDefinitions[1]
	local valid: boolean, reason: string? =
		Validate.Validate(domain.state, { ["Private.Refresh"] = { stackCount = 1 } })
	expect(valid).toBe(false)
	expect(reason).toBe("SchemaEnumValueInvalid")
	for _, event: ReplicationTypes.LoadedReplicationEventDefinition in domain.events do
		local eventValid: boolean, eventReason: string? = Validate.Validate(event.payload, "Private.Refresh")
		expect(eventValid).toBe(false)
		expect(eventReason).toBe("SchemaEnumValueInvalid")
	end
end)
