--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local ActorTypes = require(ReplicatedStorage.Packages.KRF.server.Actor.types)
local SignalTypes = require(ReplicatedStorage.Packages.KRF.shared.Signal.types)

type Actor = ActorTypes.Actor
type ActorRuntimeT = ActorTypes.ActorRuntime
type ActorRegistryT = ActorTypes.ActorRegistry
type RegisterActorOpts = ActorTypes.RegisterActorOpts
type Connection = SignalTypes.Connection

local ActorRuntime: ActorRuntimeT = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorRuntime)
local ActorRegistry: ActorRegistryT = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorRegistry)

it("UnregisterActor unbinds after controller cleanup (model destroyed during DetachAllControllers)", function()
	local ActorEntity = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorEntity)

	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local actor: Actor = ActorEntity.new()
	local bindOk: boolean, bindReason: string? = ActorRegistry.BindModel(actor, model)
	expect(bindOk).toBe(true)
	expect(bindReason).toBeNil()

	actor.enabled = true

	local boundDuringDetach: boolean? = nil
	local originalDetach = ActorRuntime.DetachAllControllers

	local function run()
		ActorRuntime.DetachAllControllers = function(a: Actor)
			model:Destroy()
			boundDuringDetach = (ActorRegistry.GetActorById(a:GetId()) ~= nil)
		end

		local unregOk: boolean, unregReason: string? = ActorRuntime.UnregisterActor(actor, "Test")
		expect(unregOk).toBe(true)
		expect(unregReason).toBeNil()

		expect(boundDuringDetach).toBe(true)

		expect(ActorRegistry.GetActorById(actor:GetId())).toBeNil()
		expect(ActorRegistry.GetActorByModel(model)).toBeNil()
		expect(actor.enabled).toBe(false)
	end

	local success: boolean, errorMessage: any = pcall(run, nil)

	-- ALWAYS restore, even if the test failed inside run()
	ActorRuntime.DetachAllControllers = originalDetach

	if not success then
		error(errorMessage)
	end
end)

it("UnregisterActor removes registry mappings (model + id) and sets enabled=false", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local actor: Actor?, reason: string? = ActorRuntime.RegisterActor(model)

	expect(reason).toBeNil()
	expect(actor).never.toBeNil()

	local registeredActor: Actor = actor :: Actor
	local actorId: string = registeredActor:GetId()

	expect(registeredActor.enabled).toBe(true)
	expect(ActorRegistry.GetActorById(actorId)).toBe(registeredActor)
	expect(ActorRegistry.GetActorByModel(model)).toBe(registeredActor)

	local ok: boolean, unregReason: string? = ActorRuntime.UnregisterActor(registeredActor, "Test")

	expect(ok).toBe(true)
	expect(unregReason).toBeNil()

	expect(registeredActor.enabled).toBe(false)
	expect(ActorRegistry.GetActorById(actorId)).toBeNil()
	expect(ActorRegistry.GetActorByModel(model)).toBeNil()

	model:Destroy()
end)

it("UnregisterActor destroys and removes all controllers", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local destroyedA: number = 0
	local destroyedB: number = 0

	local controllerA: ActorTypes.Controller = {
		Destroy = function()
			destroyedA += 1
		end,
	}

	local controllerB: ActorTypes.Controller = {
		Destroy = function()
			destroyedB += 1
		end,
	}

	local attachCalled: boolean = false
	local attachSawEnabledFalse: boolean = false

	local originalAttach = ActorRuntime.AttachControllers

	local function run()
		ActorRuntime.AttachControllers = function(actor: Actor): (boolean, string?)
			attachCalled = true
			attachSawEnabledFalse = (actor.enabled == false)

			local okA: boolean = actor:SetController("A", controllerA)
			local okB: boolean = actor:SetController("B", controllerB)

			if not okA or not okB then
				return false, "SetControllerFailed"
			end

			return true, nil
		end

		local actor: Actor?, reason: string? = ActorRuntime.RegisterActor(model)

		expect(reason).toBeNil()
		expect(actor).never.toBeNil()

		local registeredActor: Actor = actor :: Actor

		expect(attachCalled).toBe(true)
		expect(attachSawEnabledFalse).toBe(true)

		expect(registeredActor:GetController("A")).never.toBeNil()
		expect(registeredActor:GetController("B")).never.toBeNil()

		local ok: boolean, unregReason: string? = ActorRuntime.UnregisterActor(registeredActor, "Test")
		expect(ok).toBe(true)
		expect(unregReason).toBeNil()

		expect(destroyedA).toBe(1)
		expect(destroyedB).toBe(1)

		expect(registeredActor:GetController("A")).toBeNil()
		expect(registeredActor:GetController("B")).toBeNil()
	end

	local success: boolean, errorMessage: any = pcall(run, nil)

	ActorRuntime.AttachControllers = originalAttach
	model:Destroy()

	if not success then
		error(errorMessage)
	end
end)

it("UnregisterActor is idempotent (second call does no work)", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local unregisteringEventCount: number = 0
	local unregisteredEventCount: number = 0

	local detachCalls: number = 0
	local unbindCalls: number = 0

	local originalDetachAllControllers = ActorRuntime.DetachAllControllers
	local originalUnbindModel = ActorRegistry.UnbindModel

	local unregisteringConnection: Connection? = nil
	local unregisteredConnection: Connection? = nil

	local function run()
		unregisteringConnection = ActorRuntime.OnActorUnregistering:Connect(function(_actor: Actor, _reason: string?)
			unregisteringEventCount += 1
		end)

		unregisteredConnection = ActorRuntime.OnActorUnregistered:Connect(function(_actor: Actor, _reason: string?)
			unregisteredEventCount += 1
		end)

		ActorRuntime.DetachAllControllers = function(actor: Actor): ()
			detachCalls += 1
			return originalDetachAllControllers(actor)
		end

		ActorRegistry.UnbindModel = function(actor: Actor): boolean
			unbindCalls += 1
			return originalUnbindModel(actor)
		end

		local actor: Actor?, registerReason: string? = ActorRuntime.RegisterActor(model)
		expect(registerReason).toBeNil()
		expect(actor).never.toBeNil()

		local registeredActor: Actor = actor :: Actor

		local firstOk: boolean, firstReason: string? = ActorRuntime.UnregisterActor(registeredActor, "Test")
		expect(firstOk).toBe(true)
		expect(firstReason).toBeNil()

		expect(unregisteringEventCount).toBe(1)
		expect(unregisteredEventCount).toBe(1)
		expect(detachCalls).toBe(1)
		expect(unbindCalls).toBe(1)

		local secondOk: boolean, secondReason: string? = ActorRuntime.UnregisterActor(registeredActor, "TestAgain")
		expect(secondOk).toBe(false)
		expect(secondReason).toBe("AlreadyUnregistered")

		-- no extra work on second call
		expect(unregisteringEventCount).toBe(1)
		expect(unregisteredEventCount).toBe(1)
		expect(detachCalls).toBe(1)
		expect(unbindCalls).toBe(1)
	end

	local success: boolean, errorMessage: any = pcall(run, nil)

	if unregisteringConnection then
		unregisteringConnection:Disconnect()
	end
	if unregisteredConnection then
		unregisteredConnection:Disconnect()
	end

	ActorRuntime.DetachAllControllers = originalDetachAllControllers
	ActorRegistry.UnbindModel = originalUnbindModel
	model:Destroy()

	if not success then
		error(errorMessage)
	end
end)

it("UnregisterActor ordering: Unregistering fires before cleanup + unbind; Unregistered fires after", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local actor: Actor?, registerReason: string? = ActorRuntime.RegisterActor(model)
	expect(registerReason).toBeNil()
	expect(actor).never.toBeNil()

	local registeredActor: Actor = actor :: Actor
	local reasonValue: string = "TestReason"

	local sawUnregisteringEvent: boolean = false
	local sawUnregisteredEvent: boolean = false
	local sawDetachAllControllers: boolean = false
	local sawUnbindModel: boolean = false

	local unregisteringReason: string? = nil
	local unregisteredReason: string? = nil

	local originalDetachAllControllers = ActorRuntime.DetachAllControllers
	local originalUnbindModel = ActorRegistry.UnbindModel

	local unregisteringConnection: Connection? = nil
	local unregisteredConnection: Connection? = nil

	local function run()
		unregisteringConnection = ActorRuntime.OnActorUnregistering:Connect(function(eventActor: Actor, reason: string?)
			expect(eventActor).toBe(registeredActor)
			sawUnregisteringEvent = true
			unregisteringReason = reason
		end)

		unregisteredConnection = ActorRuntime.OnActorUnregistered:Connect(function(eventActor: Actor, reason: string?)
			expect(eventActor).toBe(registeredActor)

			-- Must be after cleanup + unbind complete
			expect(sawDetachAllControllers).toBe(true)
			expect(sawUnbindModel).toBe(true)

			sawUnregisteredEvent = true
			unregisteredReason = reason
		end)

		ActorRuntime.DetachAllControllers = function(eventActor: Actor): ()
			-- Must occur after Unregistering fired
			expect(sawUnregisteringEvent).toBe(true)

			sawDetachAllControllers = true
			return originalDetachAllControllers(eventActor)
		end

		ActorRegistry.UnbindModel = function(eventActor: Actor): boolean
			-- Must occur after Unregistering fired and after detach begins
			expect(sawUnregisteringEvent).toBe(true)
			expect(sawDetachAllControllers).toBe(true)

			sawUnbindModel = true
			return originalUnbindModel(eventActor)
		end

		local unregisterOk: boolean, unregisterReason: string? =
			ActorRuntime.UnregisterActor(registeredActor, reasonValue)
		expect(unregisterOk).toBe(true)
		expect(unregisterReason).toBeNil()

		-- Give signals a moment if the signal impl dispatches on the scheduler
		for _i: number = 1, 30 do
			if sawUnregisteredEvent then
				break
			end
			task.wait()
		end

		expect(sawUnregisteringEvent).toBe(true)
		expect(sawDetachAllControllers).toBe(true)
		expect(sawUnbindModel).toBe(true)
		expect(sawUnregisteredEvent).toBe(true)

		expect(unregisteringReason).toBe(reasonValue)
		expect(unregisteredReason).toBe(reasonValue)
	end

	local success: boolean, errorMessage: any = pcall(run, nil)

	if unregisteringConnection then
		unregisteringConnection:Disconnect()
	end
	if unregisteredConnection then
		unregisteredConnection:Disconnect()
	end

	ActorRuntime.DetachAllControllers = originalDetachAllControllers
	ActorRegistry.UnbindModel = originalUnbindModel
	model:Destroy()

	if not success then
		error(errorMessage)
	end
end)

it("ModelGone triggers full teardown via ActorRuntime (reason=ModelGone)", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local destroyedCount: number = 0
	local controllerKey: string = "ModelGoneController"

	local controller: ActorTypes.Controller = {
		Destroy = function()
			destroyedCount += 1
		end,
	}

	local unregisteringEventCount: number = 0
	local unregisteredEventCount: number = 0
	local unregisteringReason: string? = nil
	local unregisteredReason: string? = nil

	local originalAttachControllers = ActorRuntime.AttachControllers

	local unregisteringConnection: Connection? = nil
	local unregisteredConnection: Connection? = nil

	local registeredActor: Actor? = nil
	local registeredActorId: string? = nil

	local function cleanup()
		if unregisteringConnection then
			unregisteringConnection:Disconnect()
			unregisteringConnection = nil
		end
		if unregisteredConnection then
			unregisteredConnection:Disconnect()
			unregisteredConnection = nil
		end

		ActorRuntime.AttachControllers = originalAttachControllers
		model:Destroy()
	end

	local function run()
		ActorRuntime.AttachControllers = function(actor: Actor): (boolean, string?)
			local ok: boolean = actor:SetController(controllerKey, controller)
			if not ok then
				return false, "SetControllerFailed"
			end
			return true, nil
		end

		unregisteringConnection = ActorRuntime.OnActorUnregistering:Connect(function(eventActor: Actor, reason: string?)
			if registeredActor ~= nil and eventActor == (registeredActor :: Actor) then
				unregisteringEventCount += 1
				unregisteringReason = reason
			end
		end)

		unregisteredConnection = ActorRuntime.OnActorUnregistered:Connect(function(eventActor: Actor, reason: string?)
			if registeredActor ~= nil and eventActor == (registeredActor :: Actor) then
				unregisteredEventCount += 1
				unregisteredReason = reason
			end
		end)

		local actor: Actor?, registerReason: string? = ActorRuntime.RegisterActor(model)
		expect(registerReason).toBeNil()
		expect(actor).never.toBeNil()

		registeredActor = actor
		registeredActorId = (actor :: Actor):GetId()

		-- sanity: controller attached and actor is live
		expect((actor :: Actor).enabled).toBe(true)
		expect((actor :: Actor):GetController(controllerKey)).never.toBeNil()
		expect(ActorRegistry.GetActorById(registeredActorId :: string)).toBe(actor :: Actor)
		expect(ActorRegistry.GetActorByModel(model)).toBe(actor :: Actor)

		model.Parent = nil

		-- wait for teardown to complete (signal dispatch may be scheduled)
		for _i: number = 1, 60 do
			if unregisteredEventCount == 1 then
				break
			end
			task.wait()
		end

		expect(unregisteringEventCount).toBe(1)
		expect(unregisteredEventCount).toBe(1)
		expect(unregisteringReason).toBe("ModelGone")
		expect(unregisteredReason).toBe("ModelGone")

		-- prove it routed through ActorRuntime teardown (controller destroyed)
		expect(destroyedCount).toBe(1)

		-- postconditions: fully torn down
		expect((actor :: Actor).enabled).toBe(false)
		expect((actor :: Actor).model).toBeNil()
		expect((actor :: Actor):GetController(controllerKey)).toBeNil()

		expect(ActorRegistry.GetActorById(registeredActorId :: string)).toBeNil()
		expect(ActorRegistry.GetActorByModel(model)).toBeNil()
	end

	local success: boolean, errorMessage: any = pcall(run, nil)
	cleanup()

	if not success then
		error(errorMessage)
	end
end)
