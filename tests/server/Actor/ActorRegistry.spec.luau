--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local ActorRegistry = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorRegistry)
local ActorEntity = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorEntity)

it("BindModel returns true and indexes actor by model and id", function()
	ActorRegistry.SetModelGoneHandler(nil)

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

it("UnbindModel returns true and clears model/id lookups and actor.model", function()
	ActorRegistry.SetModelGoneHandler(nil)

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

it("BindModel rejects a different actor for an already-registered model (no overwrite)", function()
	ActorRegistry.SetModelGoneHandler(nil)

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

it("Auto-cleanup unbinds when the bound model is destroyed (model/id lookups cleared)", function()
	ActorRegistry.SetModelGoneHandler(nil)

	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local actor: ActorEntity.Actor = ActorEntity.new()
	ActorRegistry.BindModel(actor, model)

	model:Destroy()

	expect(ActorRegistry.GetActorByModel(model)).toBeNil()
	expect(ActorRegistry.GetActorById(actor:GetId())).toBeNil()
	expect(actor.model).toBeNil()
end)

it("Auto-cleanup unbinds when the bound model is removed from the DataModel (Parent=nil)", function()
	ActorRegistry.SetModelGoneHandler(nil)

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

it("Parent changes within the DataModel do not trigger model-gone cleanup", function()
	ActorRegistry.SetModelGoneHandler(nil)

	local originalParent: Folder = Instance.new("Folder")
	originalParent.Parent = workspace

	local newParent: Folder = Instance.new("Folder")
	newParent.Parent = workspace

	local model: Model = Instance.new("Model")
	model.Parent = originalParent

	local actor: ActorEntity.Actor = ActorEntity.new()
	local ok: boolean, reason: string? = ActorRegistry.BindModel(actor, model)

	expect(ok).toBe(true)
	expect(reason).toBeNil()

	model.Parent = newParent

	expect(ActorRegistry.GetActorByModel(model)).toBe(actor)
	expect(ActorRegistry.GetActorById(actor:GetId())).toBe(actor)
	expect(actor.model).toBe(model)

	model:Destroy()
	originalParent:Destroy()
	newParent:Destroy()
end)

it("BindModel rejects binding an actor that is already bound to a different model", function()
	ActorRegistry.SetModelGoneHandler(nil)

	local firstModel: Model = Instance.new("Model")
	firstModel.Parent = workspace

	local secondModel: Model = Instance.new("Model")
	secondModel.Parent = workspace

	local actor: ActorEntity.Actor = ActorEntity.new()
	local ok: boolean, reason: string? = ActorRegistry.BindModel(actor, firstModel)

	expect(ok).toBe(true)
	expect(reason).toBeNil()

	ok, reason = ActorRegistry.BindModel(actor, secondModel)

	expect(ok).toBe(false)
	expect(reason).toBe("ActorHasDifferentModelBinded")
	expect(ActorRegistry.GetActorByModel(firstModel)).toBe(actor)
	expect(ActorRegistry.GetActorByModel(secondModel)).toBeNil()
	expect(ActorRegistry.GetActorById(actor:GetId())).toBe(actor)

	firstModel:Destroy()
	secondModel:Destroy()
end)

it("UnbindModel returns false when the actor is not registered", function()
	ActorRegistry.SetModelGoneHandler(nil)

	local actor: ActorEntity.Actor = ActorEntity.new()

	expect(ActorRegistry.UnbindModel(actor)).toBe(false)
end)

it("BindModel repairs a stale id record when actor.model was cleared without unregistering", function()
	ActorRegistry.SetModelGoneHandler(nil)

	local firstModel: Model = Instance.new("Model")
	firstModel.Parent = workspace

	local secondModel: Model = Instance.new("Model")
	secondModel.Parent = workspace

	local actor: ActorEntity.Actor = ActorEntity.new()
	local ok: boolean, reason: string? = ActorRegistry.BindModel(actor, firstModel)

	expect(ok).toBe(true)
	expect(reason).toBeNil()

	actor.model = nil

	ok, reason = ActorRegistry.BindModel(actor, secondModel)

	expect(ok).toBe(true)
	expect(reason).toBeNil()
	expect(ActorRegistry.GetActorById(actor:GetId())).toBe(actor)
	expect(ActorRegistry.GetActorByModel(secondModel)).toBe(actor)
	expect(ActorRegistry.GetActorByModel(firstModel)).toBeNil()
	expect(actor.model).toBe(secondModel)

	ActorRegistry.UnbindModel(actor)
	firstModel:Destroy()
	secondModel:Destroy()
end)

it("ModelGone handler receives the actor and stable reason and can own cleanup", function()
	local observedActor: ActorEntity.Actor? = nil
	local observedReason: string? = nil

	ActorRegistry.SetModelGoneHandler(function(actor: ActorEntity.Actor, reason: string)
		observedActor = actor
		observedReason = reason
		ActorRegistry.UnbindModel(actor)
	end)

	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local actor: ActorEntity.Actor = ActorEntity.new()
	local ok: boolean, reason: string? = ActorRegistry.BindModel(actor, model)

	expect(ok).toBe(true)
	expect(reason).toBeNil()

	model:Destroy()

	expect(observedActor).toBe(actor)
	expect(observedReason).toBe("ModelGone")
	expect(ActorRegistry.GetActorById(actor:GetId())).toBeNil()
	expect(ActorRegistry.GetActorByModel(model)).toBeNil()
	expect(actor.model).toBeNil()

	ActorRegistry.SetModelGoneHandler(nil)
end)

it("ModelGone fallback cleanup tolerates a stale binding record after the handler partially cleaned up", function()
	ActorRegistry.SetModelGoneHandler(function(actor: ActorEntity.Actor, _reason: string)
		ActorRegistry.UnbindModel(actor)
		error("handler failed after cleanup")
	end)

	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local actor: ActorEntity.Actor = ActorEntity.new()
	local ok: boolean, reason: string? = ActorRegistry.BindModel(actor, model)

	expect(ok).toBe(true)
	expect(reason).toBeNil()

	model:Destroy()

	expect(ActorRegistry.GetActorById(actor:GetId())).toBeNil()
	expect(ActorRegistry.GetActorByModel(model)).toBeNil()
	expect(actor.model).toBeNil()

	ActorRegistry.SetModelGoneHandler(nil)
end)

it("ModelGone falls back to cleanup when the handler errors", function()
	ActorRegistry.SetModelGoneHandler(function(_actor: ActorEntity.Actor, _reason: string)
		error("handler failed")
	end)

	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local actor: ActorEntity.Actor = ActorEntity.new()
	local ok: boolean, reason: string? = ActorRegistry.BindModel(actor, model)

	expect(ok).toBe(true)
	expect(reason).toBeNil()

	model:Destroy()

	expect(ActorRegistry.GetActorById(actor:GetId())).toBeNil()
	expect(ActorRegistry.GetActorByModel(model)).toBeNil()
	expect(actor.model).toBeNil()

	ActorRegistry.SetModelGoneHandler(nil)
end)
