--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect

local ActorTypes = require(ReplicatedStorage.Packages.KRF.server.Actor.types)
local ControllerTypes = require(ReplicatedStorage.Packages.KRF.server.Controller.types)

type Actor = ActorTypes.Actor
type Controller = ActorTypes.Controller
type ControllerDef = ControllerTypes.ControllerDef
type ControllerRegistryT = ControllerTypes.ControllerRegistry

local ActorEntity = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorEntity)
local ActorRuntime = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorRuntime)
local ControllerRegistry: ControllerRegistryT =
	require(ReplicatedStorage.Packages.KRF.server.Controller.ControllerRegistry)

it("ActorRuntime.AttachControllers fails when the controller key is already occupied", function()
	ControllerRegistry._ResetForTests()

	local actor: Actor = ActorEntity.new()

	local existingDestroyCount: number = 0
	local existingController: Controller = {
		Destroy = function()
			existingDestroyCount += 1
		end,
	}

	local setOk: boolean = actor:SetController("A", existingController)
	expect(setOk).toBe(true)

	local newDestroyCount: number = 0
	local controllerDefA: ControllerDef = {
		key = "A",
		autoAttach = true,
		factory = function(_actor: Actor): Controller
			local newController: Controller = {
				Destroy = function()
					newDestroyCount += 1
				end,
			}
			return newController
		end,
	}

	local okReg: boolean, regReason: string? = ControllerRegistry.Register(controllerDefA)
	expect(okReg).toBe(true)
	expect(regReason).toBeNil()

	local okAttach: boolean, attachReason: string? = ActorRuntime.AttachControllers(actor)
	expect(okAttach).toBe(false)
	expect(attachReason).toBe("ControllerAttachmentFailed:A")

	local stillStored: Controller? = actor:GetController("A")
	expect(stillStored).toBe(existingController)

	expect(existingDestroyCount).toBe(0)
	expect(newDestroyCount).toBe(1)

	ControllerRegistry._ResetForTests()
end)

it("ActorRuntime.AttachControllers rolls back controllers attached in the current call on failure", function()
	ControllerRegistry._ResetForTests()

	local actor: Actor = ActorEntity.new()

	local aDestroyCount: number = 0

	local controllerDefA: ControllerDef = {
		key = "A",
		autoAttach = true,
		factory = function(_actor: Actor): Controller
			local controllerA: Controller = {
				Destroy = function()
					aDestroyCount += 1
				end,
			}
			return controllerA
		end,
	}

	local controllerDefB: ControllerDef = {
		key = "B",
		autoAttach = true,
		dependsOn = { "A" },
		factory = function(_actor: Actor): Controller
			error("factory boom")
		end,
	}

	local okA: boolean, reasonA: string? = ControllerRegistry.Register(controllerDefA)
	local okB: boolean, reasonB: string? = ControllerRegistry.Register(controllerDefB)

	expect(okA).toBe(true)
	expect(reasonA).toBeNil()
	expect(okB).toBe(true)
	expect(reasonB).toBeNil()

	local okAttach: boolean, attachReason: string? = ActorRuntime.AttachControllers(actor)
	expect(okAttach).toBe(false)
	expect(attachReason).toBe("FactoryError:B")

	local controllerA: Controller? = actor:GetController("A")
	local controllerB: Controller? = actor:GetController("B")

	expect(controllerA).toBeNil()
	expect(controllerB).toBeNil()
	expect(aDestroyCount).toBe(1)

	ControllerRegistry._ResetForTests()
end)

it("ActorRuntime.DetachAllControllers destroys and removes all controllers", function()
	local actor: Actor = ActorEntity.new()

	local destroyCountA: number = 0
	local destroyCountB: number = 0

	local controllerA: Controller = {
		Destroy = function()
			destroyCountA += 1
		end,
	}

	local controllerB: Controller = {
		Destroy = function()
			destroyCountB += 1
		end,
	}

	local okA: boolean = actor:SetController("A", controllerA)
	local okB: boolean = actor:SetController("B", controllerB)

	expect(okA).toBe(true)
	expect(okB).toBe(true)

	ActorRuntime.DetachAllControllers(actor)

	expect(actor:GetController("A")).toBeNil()
	expect(actor:GetController("B")).toBeNil()
	expect(destroyCountA).toBe(1)
	expect(destroyCountB).toBe(1)
end)

it("ActorRuntime.DetachAllControllers is idempotent", function()
	local actor: Actor = ActorEntity.new()

	local destroyCount: number = 0
	local controllerA: Controller = {
		Destroy = function()
			destroyCount += 1
		end,
	}

	local okA: boolean = actor:SetController("A", controllerA)
	expect(okA).toBe(true)

	ActorRuntime.DetachAllControllers(actor)
	ActorRuntime.DetachAllControllers(actor)

	expect(actor:GetController("A")).toBeNil()
	expect(destroyCount).toBe(1)
end)
