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

it("ActorRuntime.AttachControllers returns the ordering failure from ControllerRegistry", function()
	ControllerRegistry._ResetForTests()

	local actor: Actor = ActorEntity.new()

	local originalResolveOrder: ({ string }) -> ({ string }?, string?) = ControllerRegistry.ResolveOrder

	local function run()
		ControllerRegistry.ResolveOrder = function(_keys: { string }): ({ string }?, string?)
			return nil, "CyclicDependency"
		end

		local okAttach: boolean, attachReason: string? = ActorRuntime.AttachControllers(actor)
		expect(okAttach).toBe(false)
		expect(attachReason).toBe("CyclicDependency")
	end

	local success: boolean, errorMessage: any = pcall(run)
	ControllerRegistry.ResolveOrder = originalResolveOrder
	ControllerRegistry._ResetForTests()

	if not success then
		error(errorMessage)
	end
end)

it("ActorRuntime.AttachControllers rejects a controller key that disappears before lookup", function()
	ControllerRegistry._ResetForTests()

	local actor: Actor = ActorEntity.new()
	local originalGetAutoAttachKeys: () -> { string } = ControllerRegistry.GetAutoAttachKeys
	local originalResolveOrder: ({ string }) -> ({ string }?, string?) = ControllerRegistry.ResolveOrder
	local originalGet: (string) -> ControllerDef? = ControllerRegistry.Get

	local function run()
		ControllerRegistry.GetAutoAttachKeys = function(): { string }
			return { "Ghost" }
		end

		ControllerRegistry.ResolveOrder = function(_keys: { string }): ({ string }?, string?)
			return { "Ghost" }, nil
		end

		ControllerRegistry.Get = function(_key: string): ControllerDef?
			return nil
		end

		local okAttach: boolean, attachReason: string? = ActorRuntime.AttachControllers(actor)
		expect(okAttach).toBe(false)
		expect(attachReason).toBe("UnknownControllerKey:Ghost")
		expect(actor:GetController("Ghost")).toBeNil()
	end

	local success: boolean, errorMessage: any = pcall(run)
	ControllerRegistry.GetAutoAttachKeys = originalGetAutoAttachKeys
	ControllerRegistry.ResolveOrder = originalResolveOrder
	ControllerRegistry.Get = originalGet
	ControllerRegistry._ResetForTests()

	if not success then
		error(errorMessage)
	end
end)

it("ActorRuntime.AttachControllers rejects a factory that does not create a controller", function()
	ControllerRegistry._ResetForTests()

	local actor: Actor = ActorEntity.new()

	local controllerDefA: ControllerDef = {
		key = "A",
		autoAttach = true,
		factory = function(_actor: Actor): Controller
			return nil :: any
		end,
	}

	local okReg: boolean, regReason: string? = ControllerRegistry.Register(controllerDefA)
	expect(okReg).toBe(true)
	expect(regReason).toBeNil()

	local okAttach: boolean, attachReason: string? = ActorRuntime.AttachControllers(actor)
	expect(okAttach).toBe(false)
	expect(attachReason).toBe("FactoryDidNotCreateController:A")
	expect(actor:GetController("A")).toBeNil()

	ControllerRegistry._ResetForTests()
end)

it("ActorRuntime.AttachControllers rejects a controller that does not satisfy the destroy contract", function()
	ControllerRegistry._ResetForTests()

	local actor: Actor = ActorEntity.new()

	local controllerDefA: ControllerDef = {
		key = "A",
		autoAttach = true,
		factory = function(_actor: Actor): Controller
			return {} :: any
		end,
	}

	local okReg: boolean, regReason: string? = ControllerRegistry.Register(controllerDefA)
	expect(okReg).toBe(true)
	expect(regReason).toBeNil()

	local okAttach: boolean, attachReason: string? = ActorRuntime.AttachControllers(actor)
	expect(okAttach).toBe(false)
	expect(attachReason).toBe("ControllerContractNotObliged:A")
	expect(actor:GetController("A")).toBeNil()

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

it("ActorRuntime.DetachAllControllers still removes controllers when Destroy errors", function()
	local actor: Actor = ActorEntity.new()

	local destroyCountA: number = 0
	local destroyCountB: number = 0

	local controllerA: Controller = {
		Destroy = function()
			destroyCountA += 1
			error("destroy boom")
		end,
	}

	local controllerB: Controller = {
		Destroy = function()
			destroyCountB += 1
		end,
	}

	local function run()
		local okA: boolean = actor:SetController("A", controllerA)
		local okB: boolean = actor:SetController("B", controllerB)

		expect(okA).toBe(true)
		expect(okB).toBe(true)

		ActorRuntime.DetachAllControllers(actor)

		expect(actor:GetController("A")).toBeNil()
		expect(actor:GetController("B")).toBeNil()
		expect(destroyCountA).toBe(1)
		expect(destroyCountB).toBe(1)
	end

	local success: boolean, errorMessage: any = pcall(run)

	if not success then
		error(errorMessage)
	end
end)
