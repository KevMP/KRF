--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Publication: Types.PublicationRuntimeModule = require(KRF.server.Networking.PublicationRuntime)
local Networking: Types.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Codec: SharedTypes.ActorStreamCodecModule = require(KRF.shared.Networking.ActorStreamCodec)
local Constants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local DomainUtils = require(script.Parent.Parent.Utils.Replication.ReplicationDomainTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
	fixture.publication:Destroy()
	fixture.ownerDomain.definition.state = Schema.String(600000)
	fixture.ownerDomain.value = string.rep("s", 600000)
	fixture.catalog = DomainUtils.prepare({ fixture.publicDomain.definition, fixture.ownerDomain.definition })

	local protocol = assert(Networking.Prepare(fixture.catalog))

	fixture.protocol = protocol
	fixture.publication = Publication.new(fixture.catalog)

	local schemas: SharedTypes.ActorSchemaCatalog = {}

	for id, definition in fixture.catalog.definitionsById do
		schemas[id] = definition.state
	end

	fixture.codec = Codec.Compile(protocol.runtime, schemas)
	fixture.options.maxBaselineBytes = Constants.MAX_BASELINE_BYTES
	fixture.options.maxChunkBytes = Constants.CHUNK_BYTES
	fixture.options.maxQueuedBytes = Constants.MAX_QUEUED_BYTES
	fixture.options.maxEvents = Constants.MAX_EVENTS
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("admits a small public anchor despite a permanently oversized private domain under default limits", function()
	local owner = TestUtils.player(fixture)
	local observer = TestUtils.player(fixture)
	local actor = TestUtils.actor(fixture, owner)
	local runtime = TestUtils.start(fixture)
	local internal: any = runtime
	expect(internal.backlog.limits.actorBytes).toBe(Constants.BACKLOG_ACTOR_BYTES)
	expect(fixture.publication:GetBaselineWeight(actor) * 2 > Constants.BACKLOG_ACTOR_BYTES).toBe(true)
	local publicBody = assert(fixture.codec.EncodeBaseline({ ["Game.Public"] = { value = 10 } }))
	expect(buffer.len(publicBody)).toBe(9)
	TestUtils.ready(fixture, observer)
	local stream = internal.connections[observer].actors[actor]
	local anchored = stream.baseline
	local retainedPrivate = anchored ~= nil and anchored.projection.domains["Game.Private"] ~= nil
	local retainedCanonicalPrivate = anchored ~= nil and anchored.projection.canonical.domains["Game.Private"] ~= nil

	fixture.publicDomain.value = 11
	fixture.publicDomain.callbacks[actor]({ { id = "Changed", payload = 11 } })

	for _ = 1, 128 do
		runtime:Step(Constants.STEP_BYTES, Constants.STEP_RECORDS)
	end

	expect(#TestUtils.kind(fixture, observer, "BaselineEnd")).toBe(1)
	expect(retainedPrivate).toBe(false)
	expect(retainedCanonicalPrivate).toBe(false)
	expect(anchored ~= nil).toBe(true)
	expect(anchored.projection.retainedBytes).toBe(buffer.len(publicBody) * 2)

	expect(TestUtils.baseline(fixture, observer, assert(runtime:GetHandle(observer, actor)))).toEqual({
		["Game.Public"] = { value = 10 },
	})

	local commits = TestUtils.kind(fixture, observer, "Commit")
	expect(#commits).toBe(1)
	expect(commits[1].events).toEqual({ { domainId = "Game.Public", eventId = "Changed", payload = 11 } })
	expect(fixture.faults).toEqual({})
	expect(internal.backlog.records).toBe(0)
	expect(internal.backlog.bytes).toBe(0)
end)

it("retains and fully charges visible private state for owners while public anchors exclude it", function()
	fixture.ownerDomain.value = string.rep("s", 100000)

	local owner = TestUtils.player(fixture)
	local observer = TestUtils.player(fixture)
	local actor = TestUtils.actor(fixture, owner)
	local runtime = TestUtils.start(fixture)
	local internal: any = runtime
	local canonical = assert(fixture.publication:CaptureBaseline(actor))
	local ownerBody = assert(fixture.codec.EncodeBaseline(canonical.domains))
	TestUtils.ready(fixture, owner)
	TestUtils.ready(fixture, observer)
	local privateAnchor = internal.connections[owner].actors[actor].baseline.projection
	local publicAnchor = internal.connections[observer].actors[actor].baseline.projection
	expect(privateAnchor.canonical.domains["Game.Private"].value).toBe(fixture.ownerDomain.value)
	expect(publicAnchor.canonical.domains["Game.Private"]).toBeNil()
	expect(privateAnchor.retainedBytes).toBe(buffer.len(ownerBody) * 2)
	expect(publicAnchor.retainedBytes).toBe(18)
	expect(internal.backlog.bytes).toBe(buffer.len(ownerBody) * 2 + 18)

	for _ = 1, 128 do
		runtime:Step(Constants.STEP_BYTES, Constants.STEP_RECORDS)
	end

	expect(#TestUtils.kind(fixture, owner, "BaselineEnd")).toBe(1)
	expect(#TestUtils.kind(fixture, observer, "BaselineEnd")).toBe(1)
	expect(TestUtils.baseline(fixture, owner, assert(runtime:GetHandle(owner, actor)))).toEqual(canonical.domains)

	expect(TestUtils.baseline(fixture, observer, assert(runtime:GetHandle(observer, actor)))).toEqual({
		["Game.Public"] = { value = 10 },
	})

	expect(internal.backlog.records).toBe(0)
	expect(internal.backlog.bytes).toBe(0)
end)
