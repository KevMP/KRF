--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect
local jest = JestGlobals.jest

local ActorTypes = require(ReplicatedStorage.Packages.KRF.server.Actor.types)
local SignalTypes = require(ReplicatedStorage.Packages.KRF.shared.Signal.types)

type Actor = ActorTypes.Actor
type ActorRuntimeT = ActorTypes.ActorRuntime
type ActorRegistryT = ActorTypes.ActorRegistry
type RegisterActorOpts = ActorTypes.RegisterActorOpts
type Connection = SignalTypes.Connection

local ActorRuntime: ActorRuntimeT = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorRuntime)
local ActorRegistry: ActorRegistryT = require(ReplicatedStorage.Packages.KRF.server.Actor.ActorRegistry)

it("RegisterActor succeeds: bind -> attach -> enable -> event", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	-- hijack AttachControllers
	local attachSawEnabledFalse: boolean = false
	local originalAttach = ActorRuntime["AttachControllers"]

	local attachMock: any = jest.fn(function(a: Actor): (boolean, string?)
		attachSawEnabledFalse = (a.enabled == false)
		return true, nil
	end)

	ActorRuntime.AttachControllers = attachMock

	local registedActorEventCount: number = 0
	local lastRegisteredActor: Actor? = nil
	local eventFiredConnection: SignalTypes.Connection<> = ActorRuntime.OnActorRegistered:Connect(
		function(registeredActor: Actor)
			registedActorEventCount += 1
			lastRegisteredActor = registeredActor
		end
	)

	local actor: Actor?, reason: string? = ActorRuntime.RegisterActor(model)

	expect(reason).toBeNil()
	expect(actor).toBeDefined()

	local registeredActor: Actor = actor :: Actor
	expect(registeredActor.model).toBe(model)
	expect(registeredActor.enabled).toBe(true)

	expect(attachMock).toHaveBeenCalledTimes(1)
	expect(attachSawEnabledFalse).toBe(true)

	expect(registedActorEventCount).toEqual(1)
	expect(lastRegisteredActor).toBe(registeredActor)

	eventFiredConnection:Disconnect()
	ActorRuntime.AttachControllers = originalAttach
	model:Destroy()
end)

it("RegisterActor success: registry lookups by model and id work", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local actor: Actor?, reason: string? = ActorRuntime.RegisterActor(model)

	expect(actor).toBeDefined()
	expect(reason).toBeNil()

	local registeredActor: Actor = actor :: Actor
	expect(ActorRegistry.GetActorById(registeredActor:GetId())).toBe(registeredActor)
	expect(ActorRegistry.GetActorByModel(model)).toBe(registeredActor)

	model:Destroy()
end)

it("RegisterActor rejects duplicate model registration (no overwrite)", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local actor: Actor?, reason: string? = ActorRuntime.RegisterActor(model)

	expect(actor).toBeDefined()
	expect(reason).toBeNil()

	local originalActor: Actor = actor :: Actor

	actor, reason = ActorRuntime.RegisterActor(model)

	expect(actor).toBeNil()
	expect(reason).toEqual("ModelAlreadyRegistered")
	expect(ActorRegistry.GetActorByModel(model)).toBe(originalActor)
	expect(ActorRegistry.GetActorById(originalActor:GetId())).toBe(originalActor)

	model:Destroy()
end)

it("OnActorRegistered fires once on success", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local firedCount: number = 0
	local firedActor: Actor? = nil

	local connection: SignalTypes.Connection = ActorRuntime.OnActorRegistered:Connect(function(a: Actor)
		firedCount += 1
		firedActor = a
	end)

	local actor: Actor?, reason: string? = ActorRuntime.RegisterActor(model)

	expect(reason).toBeNil()
	expect(actor).never.toBeNil()
	local registeredActor: Actor = actor :: Actor

	for _i: number = 1, 30 do
		if firedCount == 1 then
			break
		end
		task.wait()
	end

	expect(firedCount).toBe(1)
	expect(firedActor).toBe(registeredActor)

	task.wait()
	task.wait()
	expect(firedCount).toBe(1)

	connection:Disconnect()
	model:Destroy()
end)

it("OnActorRegistered never fires on BindModel failure", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local firedCount: number = 0
	local connection: SignalTypes.Connection = ActorRuntime.OnActorRegistered:Connect(function(_a: Actor)
		firedCount += 1
	end)

	-- First registration succeeds (event should fire once)
	local actor: Actor?, reason: string? = ActorRuntime.RegisterActor(model)
	expect(reason).toBeNil()
	expect(actor).never.toBeNil()

	for _i: number = 1, 30 do
		if firedCount == 1 then
			break
		end
		task.wait()
	end
	expect(firedCount).toBe(1)

	-- Reset counter to observe the failing attempt
	firedCount = 0

	-- Second registration fails at BindModel (duplicate model)
	local actor2: Actor?, reason2: string? = ActorRuntime.RegisterActor(model)
	expect(actor2).toBeNil()
	expect(reason2).toEqual("ModelAlreadyRegistered")

	-- Give GoodSignal/task.spawn a moment; should remain zero
	task.wait()
	task.wait()
	expect(firedCount).toBe(0)

	connection:Disconnect()
	model:Destroy()
end)

it("AttachControllers failure triggers full rollback (no residue)", function()
	local model: Model = Instance.new("Model")
	model.Parent = workspace

	local firedCount: number = 0
	local connection: SignalTypes.Connection = ActorRuntime.OnActorRegistered:Connect(function(_a: Actor)
		firedCount += 1
	end)

	-- Capture what happened inside the hijacked hooks
	local attachCalled: boolean = false
	local attachSawEnabledFalse: boolean = false
	local capturedActor: Actor? = nil
	local capturedActorId: string? = nil

	local detachCalls: number = 0
	local detachedActor: Actor? = nil

	-- Save originals (typed via the ActorRuntime table-type)
	local originalAttach = ActorRuntime.AttachControllers
	local originalDetach = ActorRuntime.DetachAllControllers

	local function cleanup()
		connection:Disconnect()
		ActorRuntime.AttachControllers = originalAttach
		ActorRuntime.DetachAllControllers = originalDetach
		model:Destroy()
	end

	local ok: boolean = pcall(function()
		ActorRuntime.AttachControllers = function(a: Actor): (boolean, string?)
			attachCalled = true
			attachSawEnabledFalse = (a.enabled == false)
			capturedActor = a
			capturedActorId = a:GetId()
			return false, "AttachFailed"
		end

		-- Hijack DetachAllControllers so we can assert rollback called it
		ActorRuntime.DetachAllControllers = function(a: Actor): ()
			detachCalls += 1
			detachedActor = a
			return
		end

		local actor: Actor?, reason: string? = ActorRuntime.RegisterActor(model)

		-- Assert: returns failure
		expect(actor).toBeNil()
		expect(reason).toEqual("AttachFailed")

		-- Assert: attach hook was invoked while actor not live
		expect(attachCalled).toBe(true)
		expect(attachSawEnabledFalse).toBe(true)
		expect(capturedActor).never.toBeNil()
		expect(capturedActorId).never.toBeNil()

		local a: Actor = capturedActor :: Actor
		local actorId: string = capturedActorId :: string

		-- Assert: rollback invoked detach exactly once for that actor
		expect(detachCalls).toBe(1)
		expect(detachedActor).toBe(a)

		-- Assert: actor not enabled + model cleared (unbind)
		expect(a.enabled).toBe(false)
		expect(a.model).toBeNil()

		-- Assert: registry residue cleared
		expect(ActorRegistry.GetActorByModel(model)).toBeNil()
		expect(ActorRegistry.GetActorById(actorId)).toBeNil()

		-- Assert: event never fired (give scheduler a couple frames just in case)
		task.wait()
		task.wait()
		expect(firedCount).toBe(0)
	end)

	expect(ok).toBe(true)
	cleanup()
end)
