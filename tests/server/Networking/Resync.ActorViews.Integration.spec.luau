--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local AwarenessTypes = require(KRF.server.Networking.AwarenessTypes)
local ResyncTypes = require(KRF.server.Networking.ResyncTypes)
local ViewTypes = require(KRF.client.Networking.ActorViewTypes)
local PublicTypes = require(KRF.client.Actor.types)
local WireTypes = require(KRF.shared.Networking.ActorStreamTypes)
local Views: ViewTypes.RuntimeModule = require(KRF.client.Networking.ActorViewRuntime)
local Resync: ResyncTypes.RuntimeModule = require(KRF.server.Networking.ResyncRuntime)
local ResyncCodec = require(KRF.shared.Networking.ResyncCodec)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local StreamUtils = require(script.Parent.Parent.Parent.client.Utils.ActorStreamTestUtils)

local fixture: TestUtils.Fixture
local awareness: AwarenessTypes.Runtime
local stream: StreamUtils.Fixture
local views: ViewTypes.Runtime
local control: ResyncTypes.Runtime
local player: Player
local actor: ActorTypes.Actor
local requests: { buffer }
local faults: { ViewTypes.Fault }
local replacementCalls: number

beforeEach(function()
	fixture = TestUtils.new()
	player = TestUtils.player(fixture)
	actor = TestUtils.actor(fixture, player)
	awareness = TestUtils.start(fixture)
	requests = {}
	faults = {}
	replacementCalls = 0
	local schemas: WireTypes.SchemaCatalog = {}
	for _, definition in fixture.catalog.orderedDefinitions do
		schemas[definition.id] = definition.state
	end
	views = Views.new(fixture.protocol.runtime, schemas, {
		SendReliable = function(payload: buffer)
			table.insert(requests, payload)
		end,
		ReportFault = function(fault: ViewTypes.Fault)
			table.insert(faults, fault)
		end,
	})
	stream = StreamUtils.new()
	stream.codec = fixture.codec
	stream.protocol = fixture.protocol.runtime
	stream.consumer = views.consumer
	StreamUtils.start(stream)
	control = Resync.new({
		Now = function(): number
			return 100
		end,
		IsClientReady = fixture.dependencies.IsClientReady,
		ObserveClientClosed = fixture.dependencies.ObserveClientClosed,
		RequestReplacementBaseline = function(recipient: Player, handle: number, reason: string?): (boolean, string?)
			replacementCalls += 1
			return awareness:RequestReplacementBaseline(recipient, handle, reason)
		end,
	}, { windowSeconds = 10, maxRequestsPerClient = 8, maxRequestsPerActor = 4 })
end)
afterEach(function()
	control:Destroy()
	StreamUtils.destroy(stream)
	views:Destroy()
	TestUtils.destroy(fixture)
end)

local function deliver(): ()
	TestUtils.drain(fixture)
	assert(stream.runtime ~= nil, "Expected real N4 client")
	for _, delivery: TestUtils.Delivery in fixture.deliveries do
		if delivery.player == player then
			local success: boolean, reason: string? = stream.runtime:Handle(delivery.payload)
			expect(reason).toBeNil()
			expect(success).toBe(true)
		end
	end
	fixture.deliveries = {}
end

local function view(): PublicTypes.ActorView
	local result: PublicTypes.ActorView? = views.registry.GetActorViewById(actor:GetId())
	assert(result ~= nil, "A real N4 baseline must publish the N5 view")
	return result
end

local function request(handle: number): (boolean, string?)
	local payload: buffer?, reason: string? = ResyncCodec.Encode(handle)
	assert(payload ~= nil, reason)
	return control:Handle(player, payload)
end

it(
	"recovers a deliberately skipped live revision through real N3 capture, N4 replacement and N5 state application",
	function()
		TestUtils.ready(fixture, player)
		deliver()
		local original: PublicTypes.ActorView = view()
		local domain: PublicTypes.DomainView? = original:GetDomain("Game.Public")
		assert(domain ~= nil, "Expected public domain")
		local changes: { PublicTypes.DomainChange } = {}
		local connection = domain.OnChanged:Connect(function(change: PublicTypes.DomainChange)
			table.insert(changes, change)
		end)
		fixture.publicDomain.value = 11
		fixture.publicDomain.callbacks[actor]()
		TestUtils.drain(fixture)
		fixture.deliveries = {} -- Explicitly omit exactly one complete logical commit.
		fixture.publicDomain.value = 12
		fixture.publicDomain.callbacks[actor]()
		deliver()
		expect(domain:GetState()).toBe(10)
		expect(#requests).toBe(1)
		local success: boolean, reason: string? = control:Handle(player, requests[1])
		expect(success).toBe(true)
		expect(reason).toBeNil()
		deliver()
		expect(view()).toBe(original)
		expect(original:GetDomain("Game.Public")).toBe(domain)
		expect(domain:GetState()).toBe(12)
		expect(changes).toEqual({ { previous = 10, current = 12, source = "Baseline" } })
		fixture.publicDomain.value = 13
		fixture.publicDomain.callbacks[actor]()
		deliver()
		expect(domain:GetState()).toBe(13)
		expect(changes[2].source).toBe("Commit")
		expect(replacementCalls).toBe(1)
		expect(#requests).toBe(1)
		connection:Disconnect()
	end
)

it("reflects actual N4 Owner reassociation by retiring and recreating only the private DomainView", function()
	TestUtils.ready(fixture, player)
	deliver()
	local original: PublicTypes.ActorView = view()
	local private: PublicTypes.DomainView? = original:GetDomain("Game.Private")
	assert(private ~= nil, "Owner must receive private state")
	local public: PublicTypes.DomainView? = original:GetDomain("Game.Public")
	TestUtils.associate(fixture, actor, nil)
	deliver()
	expect(view()).toBe(original)
	expect(original:GetDomain("Game.Public")).toBe(public)
	expect(original:GetDomain("Game.Private")).toBeNil()
	local readable: boolean, state: any = pcall(function(): any
		return private:GetState()
	end)
	if readable then
		expect(state).toBeNil()
	end
	TestUtils.associate(fixture, actor, player)
	deliver()
	local restored: PublicTypes.DomainView? = original:GetDomain("Game.Private")
	assert(restored ~= nil, "Owner visibility gain must restore private state")
	expect(restored).never.toBe(private)
	expect(restored:GetState()).toBe(20)
	expect(requests).toEqual({})
end)

it("deduplicates a real pending replacement and rejects a removing Actor without another snapshot capture", function()
	TestUtils.ready(fixture, player)
	deliver()
	local handle: number? = awareness:GetHandle(player, actor)
	assert(handle ~= nil, "Expected connection-local handle")
	expect(request(handle)).toBe(true)
	local captures: number = fixture.publicDomain.snapshotCalls
	local success: boolean, reason: string? = request(handle)
	expect(success).toBe(false)
	expect(reason).toBe("BaselineAlreadyPending")
	expect(fixture.publicDomain.snapshotCalls).toBe(captures)
	awareness:OnActorUnregistering(actor)
	success, reason = request(handle)
	expect(success).toBe(false)
	expect(reason).toBe("UnknownActorHandle")
	expect(fixture.publicDomain.snapshotCalls).toBe(captures)
	deliver()
	expect(views.registry.GetActorViewById(actor:GetId())).toBeNil()
end)

it("rejects a real unready or unknown stream without invoking any domain mutation or snapshot", function()
	local captures: number = fixture.publicDomain.snapshotCalls
	local success: boolean, reason: string? = request(1)
	expect(success).toBe(false)
	expect(reason).toBe("ClientNotReady")
	expect(replacementCalls).toBe(0)
	TestUtils.ready(fixture, player)
	deliver()
	captures = fixture.publicDomain.snapshotCalls
	success, reason = request(99)
	expect(success).toBe(false)
	expect(reason).toBe("UnknownActorHandle")
	expect(fixture.publicDomain.snapshotCalls).toBe(captures)
	expect(fixture.publicDomain.value).toBe(10)
	expect(fixture.ownerDomain.value).toBe(20)
end)
