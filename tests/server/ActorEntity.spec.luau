--!strict
local JestGlobals = require(game.ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local ActorEntity = require(game.ReplicatedStorage.Packages.KRF.server.Actor.ActorEntity)

it("returns a stable id and ignores external id field writes", function()
	local actor: ActorEntity.Actor = ActorEntity.new()

	local id1 = actor:GetId();

	(actor :: any).id = "altered value"

	local id2 = actor:GetId()

	expect(id2).toEqual(id1)
end)

it("does not expose an id setter", function()
	local actor: ActorEntity.Actor = ActorEntity.new()
	expect((actor :: any).SetId).toBe(nil)
end)

it("defaults enabled to false and allows deterministic toggling", function()
	local actor: ActorEntity.Actor = ActorEntity.new()
	expect(actor.enabled).toBe(false)

	actor.enabled = true
	expect(actor.enabled).toBe(true)

	actor.enabled = false
	expect(actor.enabled).toBe(false)
end)

it("sets, gets, and removes controllers by key", function()
	local actor: ActorEntity.Actor = ActorEntity.new()
	local controller1: ActorEntity.Controller = {
		Destroy = function(_self) end,
	}

	expect(actor:SetController("controller1", controller1)).toEqual(true)
	expect(actor:GetController("controller1")).toBe(controller1)
	expect(actor:RemoveController("controller1")).toBe(controller1)
	expect(actor:GetController("controller1")).toBe(nil)
end)

it("rejects controller overwrite until removed", function()
	local actor: ActorEntity.Actor = ActorEntity.new()
	local controller1: ActorEntity.Controller = {
		Destroy = function(_self) end,
	}
	local controller2: ActorEntity.Controller = {
		Destroy = function(_self) end,
	}

	expect(actor:SetController("controller1", controller1)).toBe(true)
	expect(actor:SetController("controller1", controller2)).toBe(false)
	expect(actor:GetController("controller1")).toBe(controller1)

	expect(actor:RemoveController("controller1")).toBe(controller1)

	expect(actor:SetController("controller1", controller2)).toBe(true)
end)

it("removing one controller does not affect other controllers", function()
	local actor: ActorEntity.Actor = ActorEntity.new()

	local controller1: ActorEntity.Controller = { Destroy = function(_self) end }
	local controller2: ActorEntity.Controller = { Destroy = function(_self) end }

	expect(actor:SetController("controller1", controller1)).toBe(true)
	expect(actor:SetController("controller2", controller2)).toBe(true)

	expect(actor:RemoveController("controller1")).toBe(controller1)

	expect(actor:GetController("controller1")).toBe(nil)
	expect(actor:GetController("controller2")).toBe(controller2)
end)
