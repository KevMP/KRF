--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local Types = require(KRF.server.Networking.AwarenessTypes)
local Marker: Types.MarkerModule = require(KRF.server.Networking.ActorModelMarker)
local ActorEntity = require(KRF.server.Actor.ActorEntity)

local model: Model
local actor: ActorTypes.Actor
local clones: { Model } = {}
beforeEach(function()
	model = Instance.new("Model")
	actor = ActorEntity.new(model)
end)
afterEach(function()
	model:Destroy()
	for _, clone: Model in clones do
		clone:Destroy()
	end
	clones = {}
end)

it("installs one private non-Archivable marker containing the bound Actor id", function()
	local success: boolean, reason: string? = Marker.Install(actor)
	expect(success).toBe(true)
	expect(reason).toBeNil()
	local marker: Instance? = Marker.GetMarker(model)
	assert(marker ~= nil, "Expected installed marker")
	expect(marker.Parent).toBe(model)
	expect(marker.Archivable).toBe(false)
	expect(Marker.GetActorId(marker)).toBe(actor:GetId())
	expect(#model:GetChildren()).toBe(1)
end)

it("deduplicates installation for the same Actor and excludes identity from a Model clone", function()
	expect(Marker.Install(actor)).toBe(true)
	local first: Instance? = Marker.GetMarker(model)
	expect(Marker.Install(actor)).toBe(true)
	expect(Marker.GetMarker(model)).toBe(first)
	local clone: Model = model:Clone()
	table.insert(clones, clone)
	expect(Marker.GetMarker(clone)).toBeNil()
	expect(#model:GetChildren()).toBe(1)
end)

it("rejects an Actor without a Model using a stable failure", function()
	local unbound: ActorTypes.Actor = ActorEntity.new()
	local success: boolean, reason: string? = Marker.Install(unbound)
	expect(success).toBe(false)
	expect(reason).toBe("ActorModelMissing")
end)

it("rejects a second Actor identity on the same Model without overwriting its first marker", function()
	expect(Marker.Install(actor)).toBe(true)
	local first: Instance? = Marker.GetMarker(model)
	local secondActor: ActorTypes.Actor = ActorEntity.new(model)
	local success: boolean, reason: string? = Marker.Install(secondActor)
	expect(success).toBe(false)
	expect(reason).toBe("ActorModelMarkerConflict")
	expect(Marker.GetMarker(model)).toBe(first)
	assert(first ~= nil, "Expected original marker")
	expect(Marker.GetActorId(first)).toBe(actor:GetId())
end)

it("removes its owned marker idempotently without deleting unrelated Model children", function()
	local unrelated: Folder = Instance.new("Folder")
	unrelated.Name = "GameChild"
	unrelated.Parent = model
	expect(Marker.Install(actor)).toBe(true)
	Marker.Remove(actor)
	Marker.Remove(actor)
	expect(Marker.GetMarker(model)).toBeNil()
	expect(unrelated.Parent).toBe(model)
	expect(model:GetChildren()).toEqual({ unrelated })
end)

it("does not let removal by an unrelated Actor erase another Actor's marker", function()
	expect(Marker.Install(actor)).toBe(true)
	local unrelated: ActorTypes.Actor = ActorEntity.new(model)
	Marker.Remove(unrelated)
	local marker: Instance? = Marker.GetMarker(model)
	assert(marker ~= nil, "Expected owned marker")
	expect(Marker.GetActorId(marker)).toBe(actor:GetId())
end)

it("clears marker ownership after Model destruction and permits repeated cleanup", function()
	expect(Marker.Install(actor)).toBe(true)
	model:Destroy()
	Marker.Remove(actor)
	Marker.Remove(actor)
	expect(Marker.GetMarker(model)).toBeNil()
end)
