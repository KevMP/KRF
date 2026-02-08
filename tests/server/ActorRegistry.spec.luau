--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local ActorRegistry = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorRegistry)
local ActorEntity = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorEntity)

it("bind -> lookup by model & id works", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local actor: ActorEntity.Actor = ActorEntity.new()
	local ok: boolean, reason: string? = ActorRegistry.BindModel(actor, model)

	expect(ok).toBe(true)
	expect(reason).toBeNil()
	expect(ActorRegistry.GetActorByModel(model)).toBe(actor)
	expect(ActorRegistry.GetActorById(actor:GetId())).toBe(actor)

	model:Destroy()
end)

it("unbind removes both indexes and lookup returns nil", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local actor: ActorEntity.Actor = ActorEntity.new()
	ActorRegistry.BindModel(actor, model)

	expect(ActorRegistry.UnbindModel(actor)).toBe(true)
	expect(ActorRegistry.GetActorById(actor:GetId())).toBeNil()
	expect(ActorRegistry.GetActorByModel(model)).toBeNil()
	expect(actor.model).toBeNil()
	model:Destroy()
end)

it("duplicate model bind returns false with ModelAlreadyRegistered and does not override", function()
	local actorA: ActorEntity.Actor = ActorEntity.new()
	local actorB: ActorEntity.Actor = ActorEntity.new()

	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local ok: boolean, reason: string? = ActorRegistry.BindModel(actorA, model)
	expect(ok).toBe(true)
	expect(reason).toBeNil()

	ok, reason = ActorRegistry.BindModel(actorB, model)
	expect(ok).toBe(false)
	expect(reason).toBe("ModelAlreadyRegistered")
	expect(ActorRegistry.GetActorByModel(model)).toBe(actorA)
	expect(ActorRegistry.GetActorById(actorB:GetId())).toBeNil()

	model:Destroy()
end)

it("actor gets cleaned up when model is destroyed", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local actor: ActorEntity.Actor = ActorEntity.new()
	ActorRegistry.BindModel(actor, model)

	model:Destroy()

	expect(ActorRegistry.GetActorByModel(model)).toBeNil()
	expect(ActorRegistry.GetActorById(actor:GetId())).toBeNil()
	expect(actor.model).toBeNil()
end)

it("actor gets cleaned up when model parent is set to nil", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local actor: ActorEntity.Actor = ActorEntity.new()
	ActorRegistry.BindModel(actor, model)

	model.Parent = nil

	expect(ActorRegistry.GetActorByModel(model)).toBeNil()
	expect(ActorRegistry.GetActorById(actor:GetId())).toBeNil()
	expect(actor.model).toBeNil()
	model:Destroy()
end)
