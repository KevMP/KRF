--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ClientNetworkingTypes = require(KRF.client.Networking.types)
local Discovery: ClientNetworkingTypes.ActorModelDiscoveryModule =
	require(KRF.client.Networking.utils.ActorModelDiscovery)
local Identity = require(KRF.shared.Networking.utils.ActorModelIdentity)

local root: Folder
local model: Model
local marker: StringValue
local discovery: ClientNetworkingTypes.ActorModelDiscoveryAdapter?
beforeEach(function()
	root = Instance.new("Folder")
	root.Parent = workspace
	model = Instance.new("Model")
	model.Parent = root
	marker = Instance.new("StringValue")
	marker.Name = Identity.NAME
	marker.Value = "ActorA"
	marker.Parent = model
	discovery = nil
end)
afterEach(function()
	if discovery ~= nil then
		discovery.Destroy()
	end
	root:Destroy()
	if marker.Parent == nil then
		marker:Destroy()
	end
end)

it("ignores malformed tagged markers and markers outside its discovery root", function()
	local wrongClass: Folder = Instance.new("Folder")
	wrongClass.Name = Identity.NAME
	wrongClass.Parent = model
	CollectionService:AddTag(wrongClass, Identity.TAG)
	CollectionService:AddTag(marker, Identity.TAG)
	marker.Name = "GameChild"
	local adapter: ClientNetworkingTypes.ActorModelDiscoveryAdapter = Discovery.new(root)
	discovery = adapter
	expect(adapter.GetCandidates()).toEqual({})
	expect(Identity.GetActorId(wrongClass)).toBeNil()
	expect(Identity.GetActorId(marker)).toBeNil()
	marker.Name = Identity.NAME
	marker.Value = ""
	task.wait()
	expect(adapter.GetCandidates()).toEqual({})
	marker.Value = "ActorA"
	marker.Parent = root
	task.wait()
	expect(adapter.GetCandidates()).toEqual({})
	marker.Parent = nil
	task.wait()
	expect(adapter.GetCandidates()).toEqual({})
	marker.Parent = model
	task.wait()
	expect(#adapter.GetCandidates()).toBe(1)
	CollectionService:RemoveTag(marker, Identity.TAG)
	task.wait()
	expect(adapter.GetCandidates()).toEqual({})
	expect(Identity.GetActorId(marker)).toBeNil()
end)

it("reconciles marker value and name changes and deduplicates valid hierarchy notifications", function()
	CollectionService:AddTag(marker, Identity.TAG)
	local adapter: ClientNetworkingTypes.ActorModelDiscoveryAdapter = Discovery.new(root)
	discovery = adapter
	local added: { string } = {}
	local removed: { Instance } = {}
	local stopAdded: () -> () = adapter.ObserveAdded(function(candidate: ClientNetworkingTypes.ActorModelCandidate)
		table.insert(added, candidate.actorId)
	end)
	local stopRemoved: () -> () = adapter.ObserveRemoved(function(instance: Instance)
		table.insert(removed, instance)
	end)
	local group: Folder = Instance.new("Folder")
	group.Parent = root
	model.Parent = group
	task.wait()
	expect(added).toEqual({})
	expect(removed).toEqual({})
	marker.Value = "ActorB"
	task.wait()
	expect(added).toEqual({ "ActorB" })
	expect(removed).toEqual({ marker })
	marker.Name = "GameChild"
	task.wait()
	expect(adapter.GetCandidates()).toEqual({})
	marker.Name = Identity.NAME
	task.wait()
	expect(added).toEqual({ "ActorB", "ActorB" })
	stopAdded()
	stopAdded()
	stopRemoved()
	stopRemoved()
	marker.Value = "ActorC"
	task.wait()
	expect(added).toEqual({ "ActorB", "ActorB" })
	expect(#removed).toBe(2)
end)

it("disconnects all native observers and rejects subscriptions after repeated destruction", function()
	CollectionService:AddTag(marker, Identity.TAG)
	local adapter: ClientNetworkingTypes.ActorModelDiscoveryAdapter = Discovery.new(root)
	discovery = adapter
	local calls: number = 0
	adapter.ObserveAdded(function(_candidate: ClientNetworkingTypes.ActorModelCandidate)
		calls += 1
	end)
	adapter.ObserveRemoved(function(_marker: Instance)
		calls += 1
	end)
	adapter.Destroy()
	adapter.Destroy()
	local stop: () -> () = adapter.ObserveAdded(function(_candidate: ClientNetworkingTypes.ActorModelCandidate)
		calls += 1
	end)
	stop()
	stop()
	marker.Value = "ActorB"
	CollectionService:RemoveTag(marker, Identity.TAG)
	CollectionService:AddTag(marker, Identity.TAG)
	task.wait()
	expect(calls).toBe(0)
	expect(adapter.GetCandidates()).toEqual({})
end)
