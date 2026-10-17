--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ServerTypes = require(KRF.server.Networking.AwarenessTypes)
local Types = require(KRF.client.Networking.ActorStreamTypes)
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local Marker: ServerTypes.MarkerModule = require(KRF.server.Networking.ActorModelMarker)
local Discovery: Types.DiscoveryModule = require(KRF.client.Networking.ActorModelDiscovery)
local TestUtils = require(script.Parent.Utils.ActorStreamTestUtils)

local fixture: TestUtils.Fixture
local root: Folder
local model: Model
local actor: ActorTypes.Actor
local discovery: Types.DiscoveryAdapter? = nil

beforeEach(function()
	fixture = TestUtils.new()
	root = Instance.new("Folder")
	root.Parent = workspace
	table.insert(fixture.instances, root)
	model = Instance.new("Model")
	model.Parent = root
	table.insert(fixture.instances, model)
	actor = ActorEntity.new(model)
	actor.enabled = true
end)
afterEach(function()
	TestUtils.destroy(fixture)
	if discovery ~= nil then
		discovery.Destroy()
		discovery = nil
	end
end)

for _, markerFirst: boolean in { true, false } do
	it(
		"binds the exact server-created marker through native client discovery when "
			.. (if markerFirst then "marker arrives first" else "awareness arrives first"),
		function()
			if markerFirst then
				local installed: boolean, reason: string? = Marker.Install(actor)
				expect(installed).toBe(true)
				expect(reason).toBeNil()
			end
			discovery = Discovery.new(root)
			fixture.discovery = discovery
			local runtime: Types.Runtime = TestUtils.start(fixture)
			TestUtils.establish(fixture, 1, actor:GetId())
			if not markerFirst then
				local installed: boolean, reason: string? = Marker.Install(actor)
				expect(installed).toBe(true)
				expect(reason).toBeNil()
			end
			-- Allow native CollectionService/ancestry notifications to run, without firing fake Candidates.
			task.wait()
			local installedMarker: Instance? = Marker.GetMarker(model)
			assert(installedMarker ~= nil, "Expected real server marker")
			local candidates: { Types.Candidate } = discovery.GetCandidates()
			expect(#candidates).toBe(1)
			expect(candidates[1].marker).toBe(installedMarker)
			expect(candidates[1].actorId).toBe(actor:GetId())
			expect(candidates[1].model).toBe(model)
			local record: Types.ActorRecord? = runtime:GetByActorId(actor:GetId())
			assert(record ~= nil, "Expected complete client awareness")
			expect(record.model).toBe(model)
			expect(runtime:GetByModel(model)).toBe(record)
			expect(fixture.bound).toEqual({ { actor = record, model = model } })
			Marker.Remove(actor)
			task.wait()
			expect(discovery.GetCandidates()).toEqual({})
			expect(runtime:GetByModel(model)).toBeNil()
			expect(runtime:GetByActorId(actor:GetId())).toBe(record)
			expect(fixture.unbound).toEqual({ { actor = record, model = model } })
		end
	)
end

it("unbinds and rebinds a real marked Model when it leaves and re-enters the discovery root", function()
	local installed: boolean, reason: string? = Marker.Install(actor)
	expect(installed).toBe(true)
	expect(reason).toBeNil()
	discovery = Discovery.new(root)
	fixture.discovery = discovery
	local runtime: Types.Runtime = TestUtils.start(fixture)
	TestUtils.establish(fixture, 1, actor:GetId(), 1, 7)
	task.wait()
	local marker: Instance? = Marker.GetMarker(model)
	local record: Types.ActorRecord? = runtime:GetByHandle(1)
	assert(record ~= nil and marker ~= nil, "Expected bound aware Model")
	expect(runtime:GetByModel(model)).toBe(record)
	model.Parent = nil
	task.wait()
	expect(discovery.GetCandidates()).toEqual({})
	expect(runtime:GetByModel(model)).toBeNil()
	expect(runtime:GetByHandle(1)).toBe(record)
	expect(record.model).toBeNil()
	model.Parent = root
	task.wait()
	expect(Marker.GetMarker(model)).toBe(marker)
	expect(runtime:GetByModel(model)).toBe(record)
	expect(record.model).toBe(model)
	expect(#fixture.baselines).toBe(1)
	expect(fixture.baselines[1].revision).toBe(7)
	expect(#fixture.bound).toBe(2)
	expect(#fixture.unbound).toBe(1)
end)
