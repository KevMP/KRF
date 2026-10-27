--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local jest: any = JestGlobals.jest
local Types = require(KRF.server.Networking.types)
local State = require(KRF.server.Networking.utils.NetworkingDiagnosticsState)
local Diagnostics = require(KRF.server.Networking.NetworkingDiagnostics)
local ActiveQueue = require(KRF.server.Networking.utils.ActiveQueue)
local TestUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture
local runtime: Types.ActorAwarenessRuntime
local player: Player

beforeEach(function()
	State.Start()
	fixture = TestUtils.new()
	player = TestUtils.player(fixture)
	TestUtils.actor(fixture, nil)
	runtime = TestUtils.start(fixture)
	TestUtils.ready(fixture, player)
end)

afterEach(function()
	jest.restoreAllMocks()
	TestUtils.destroy(fixture)
	State.Stop()
end)

it("keeps repeated queue requests idempotent without insertion attempts or unchanged gauge writes", function()
	local internal: any = runtime
	local connection = internal.connections[player]
	local pushes = jest.spyOn(ActiveQueue, "Push")
	local owner = assert(State.GetConnection(player))
	local changes = jest.spyOn(owner, "Set")

	for _ = 1, 32 do
		internal.delivery:Queue(connection)
	end

	expect(pushes).never.toHaveBeenCalled()
	expect(changes).never.toHaveBeenCalled()
	expect(internal.delivery.active.count).toBe(1)
	expect(assert(Diagnostics.GetConnectionSnapshot(player)).gauges.reliableActiveConnections.current).toBe(1)
	TestUtils.drain(fixture)
	local activeChanges = 0

	for _, call in changes.mock.calls do
		if call[2] == "reliableActiveConnections" then
			activeChanges += 1
			expect(call[3]).toBe(0)
		end
	end

	expect(activeChanges).toBe(1)
	expect(internal.delivery.active.count).toBe(0)
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(1)
end)

it("retains a re-Ready session queued during a send and releases only the old session's work", function()
	local replaced = false
	local send = fixture.dependencies.SendReliable

	fixture.dependencies.SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
		if not replaced then
			replaced = true
			TestUtils.close(fixture, player)
			TestUtils.ready(fixture, player)
		end

		return send(recipient, payload)
	end

	runtime:Step(512, 8)
	expect(assert(Diagnostics.GetConnectionSnapshot(player)).gauges.reliableActiveConnections.current).toBe(1)
	TestUtils.drain(fixture)
	expect(#TestUtils.kind(fixture, player, "BaselineEnd")).toBe(1)
	expect(assert(Diagnostics.GetServerSnapshot()).gauges.reliableRecords.current).toBe(0)
	expect(assert(Diagnostics.GetServerSnapshot()).gauges.reliableActiveConnections.current).toBe(0)
end)

it("reactivates publication queued by a send callback after releasing the staged lease", function()
	TestUtils.drain(fixture)
	fixture.deliveries = {}

	local internal: any = runtime
	local actor = internal.connections[player].handles[1].actor

	fixture.publicDomain.value = 11
	fixture.publicDomain.callbacks[actor]()
	local send = fixture.dependencies.SendReliable
	local changed = false

	fixture.dependencies.SendReliable = function(recipient: Player, payload: buffer): (boolean, string?)
		if not changed then
			changed = true
			fixture.publicDomain.value = 12
			fixture.publicDomain.callbacks[actor]()
		end

		return send(recipient, payload)
	end

	runtime:Step(512, 8)
	expect(internal.delivery.active.count).toBe(1)
	expect(assert(Diagnostics.GetServerSnapshot()).gauges.reliableRecords.current).toBe(1)
	TestUtils.drain(fixture)
	local commits = TestUtils.kind(fixture, player, "Commit")
	expect(#commits).toBe(2)
	expect(commits[1].patches[1].patch.value).toBe(11)
	expect(commits[2].patches[1].patch.value).toBe(12)
	expect(assert(Diagnostics.GetServerSnapshot()).gauges.reliableRecords.current).toBe(0)
end)
