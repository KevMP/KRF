--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local PublicTypes = require(KRF.client.Actor.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local StatePlan = require(KRF.client.Networking.utils.ActorStatePlan)
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)
local StreamUtils = require(script.Parent.Utils.ActorStreamTestUtils)

local originalCompile: typeof(StatePlan.Compile) = StatePlan.Compile
local fixture: TestUtils.Fixture
local compiled: number
local snapshots: number
local applications: number
beforeEach(function()
	compiled = 0
	snapshots = 0
	applications = 0
	StatePlan.Compile = function(schema: SharedNetworkingTypes.CompiledSchema): StatePlan.Plan
		compiled += 1
		local plan: StatePlan.Plan = originalCompile(schema)
		return {
			Snapshot = function(value: any): (StatePlan.Result?, string?)
				snapshots += 1
				return plan.Snapshot(value)
			end,
			Apply = function(previous: any, patch: SharedNetworkingTypes.ActorPatch): (StatePlan.Result?, string?)
				applications += 1
				return plan.Apply(previous, patch)
			end,
		}
	end
	fixture = TestUtils.new()
end)
afterEach(function()
	TestUtils.destroy(fixture)
	StatePlan.Compile = originalCompile
end)

it("uses only the touched domain's application plan among forty-eight live Actors", function()
	local prior: { any } = {}
	for handle: number = 1, 48 do
		local actorId: string = "Actor" .. tostring(handle)
		TestUtils.baseline(fixture, handle, actorId)
		prior[handle] = TestUtils.domain(fixture, nil, actorId):GetState()
	end
	local prepared: number = compiled
	expect(prepared > 0).toBe(true)
	snapshots = 0
	applications = 0
	TestUtils.commit(fixture, 11, { TestUtils.patch(75) }, {}, 24)
	expect(applications).toBe(1)
	expect(snapshots).toBe(0)
	expect(compiled).toBe(prepared)
	for handle: number = 1, 48 do
		local current: any = TestUtils.domain(fixture, nil, "Actor" .. tostring(handle)):GetState()
		if handle == 24 then
			expect(current.current).toBe(75)
			expect(rawequal(current.effects, prior[handle].effects)).toBe(true)
		else
			expect(rawequal(current, prior[handle])).toBe(true)
		end
	end
end)

it(
	"performs no state application, capture, codec compilation or Model rediscovery during idle frames and registry reads",
	function()
		local models: { Model } = {}
		local views: { PublicTypes.ActorView } = {}
		for handle: number = 1, 48 do
			local actorId: string = "Actor" .. tostring(handle)
			local candidate = StreamUtils.candidate(fixture.stream, actorId)
			StreamUtils.add(fixture.stream, candidate)
			models[handle] = candidate.model
			TestUtils.baseline(fixture, handle, actorId)
			views[handle] = TestUtils.view(fixture, actorId)
		end
		local prepared: number = compiled
		snapshots = 0
		applications = 0
		for _ = 1, 2 do
			task.wait()
		end
		for handle: number = 48, 1, -1 do
			expect(fixture.runtime.registry.GetActorViewById("Actor" .. tostring(handle))).toBe(views[handle])
			expect(fixture.runtime.registry.GetActorViewByModel(models[handle])).toBe(views[handle])
		end
		expect(snapshots).toBe(0)
		expect(applications).toBe(0)
		expect(compiled).toBe(prepared)
		expect(fixture.stream.scans).toBe(1)
		expect(fixture.requests).toEqual({})
	end
)

it("does no schema application for dropped recovery traffic and keeps unrelated Actors available", function()
	TestUtils.baseline(fixture)
	TestUtils.baseline(fixture, 2, "ActorB")
	local other: PublicTypes.ActorView = TestUtils.view(fixture, "ActorB")
	TestUtils.commit(fixture, 12)
	snapshots = 0
	applications = 0
	for revision: number = 11, 266 do
		TestUtils.commit(fixture, revision, { TestUtils.patch(1) })
	end
	expect(applications).toBe(0)
	expect(snapshots).toBe(0)
	expect(TestUtils.view(fixture, "ActorB")).toBe(other)
	expect(#fixture.requests).toBe(1)
end)
