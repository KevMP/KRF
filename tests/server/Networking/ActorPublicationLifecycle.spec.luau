--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ServerTypes = require(KRF.server.types)
local SignalTypes = require(KRF.shared.Signal.types)
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local Server = require(KRF.server)
local ActorRuntime: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local ActorRegistry: ActorTypes.ActorRegistry = require(KRF.server.Actor.ActorRegistry)
local Lifecycle: ServerNetworkingTypes.PublicationLifecycleModule =
	require(KRF.server.Networking.utils.ActorPublicationLifecycle)

local originalAttach: typeof(Lifecycle.AttachActor) = Lifecycle.AttachActor
local originalDetach: typeof(Lifecycle.DetachActor) = Lifecycle.DetachActor
local model: Model
local actors: { ActorTypes.Actor } = {}
local connections: { SignalTypes.Connection<> } = {}
local order: { string } = {}

beforeEach(function()
	Server._ResetForTests()
	actors = {}
	connections = {}
	order = {}
	model = Instance.new("Model")
	model.Parent = workspace
	Lifecycle.AttachActor = function(_actor: ActorTypes.Actor): (boolean, string?)
		table.insert(order, "AttachPublication")
		return true, nil
	end
	Lifecycle.DetachActor = function(_actor: ActorTypes.Actor): ()
		table.insert(order, "DetachPublication")
	end
	local success: boolean, failure: ServerTypes.StartupFailure? = Server.Init({
		controllers = {
			{
				key = "Game.Controller",
				factory = function(_actor: ActorTypes.Actor): ActorTypes.Controller
					table.insert(order, "AttachController")
					return {
						Destroy = function(): ()
							table.insert(order, "DestroyController")
						end,
					}
				end,
			},
		},
	})
	expect(success).toBe(true)
	expect(failure).toBeNil()
end)

afterEach(function()
	for _, connection: SignalTypes.Connection<> in connections do
		connection:Disconnect()
	end
	for _, actor: ActorTypes.Actor in actors do
		if actor.enabled then
			ActorRuntime.UnregisterActor(actor)
		end
	end
	model:Destroy()
	Lifecycle.AttachActor = originalAttach
	Lifecycle.DetachActor = originalDetach
	Server._ResetForTests()
end)

local function register(): (ActorTypes.Actor?, string?)
	local actor: ActorTypes.Actor?, reason: string? = ActorRuntime.RegisterActor(model)
	if actor ~= nil then
		table.insert(actors, actor)
	end
	return actor, reason
end

it("attaches Networking after controllers and before enabling or notifying consumers", function()
	local enabledAtAttach: boolean? = nil
	local controllerAtAttach: ActorTypes.Controller? = nil
	Lifecycle.AttachActor = function(actor: ActorTypes.Actor): (boolean, string?)
		enabledAtAttach = actor.enabled
		controllerAtAttach = actor:GetController("Game.Controller")
		table.insert(order, "AttachPublication")
		return true, nil
	end
	table.insert(
		connections,
		ActorRuntime.OnActorRegistered:Connect(function(): ()
			table.insert(order, "PublicRegistered")
		end)
	)
	local actor: ActorTypes.Actor?, reason: string? = register()
	expect(reason).toBeNil()
	assert(actor ~= nil, "Expected registered Actor")
	expect(enabledAtAttach).toBe(false)
	expect(controllerAtAttach).toBe(actor:GetController("Game.Controller"))
	expect(actor.enabled).toBe(true)
	expect(order).toEqual({ "AttachController", "AttachPublication", "PublicRegistered" })
end)

it("observes a mutation immediately after RegisterActor returns without waiting for public callbacks", function()
	local notification: (() -> ())? = nil
	local observedMutations: number = 0
	Lifecycle.AttachActor = function(_actor: ActorTypes.Actor): (boolean, string?)
		notification = function(): ()
			observedMutations += 1
		end
		return true, nil
	end
	local actor: ActorTypes.Actor?, reason: string? = register()
	expect(reason).toBeNil()
	assert(actor ~= nil, "Expected registered Actor")
	assert(notification ~= nil, "Committed observer must be attached before RegisterActor returns")
	notification()
	expect(observedMutations).toBe(1)
end)

it("establishes the committed observer before a public registration callback can mutate authority", function()
	local attached: boolean = false
	local attachedAtPublicCallback: boolean? = nil
	Lifecycle.AttachActor = function(_actor: ActorTypes.Actor): (boolean, string?)
		attached = true
		return true, nil
	end
	table.insert(
		connections,
		ActorRuntime.OnActorRegistered:Connect(function(): ()
			attachedAtPublicCallback = attached
		end)
	)
	local actor: ActorTypes.Actor?, reason: string? = register()
	expect(reason).toBeNil()
	expect(actor ~= nil).toBe(true)
	expect(attachedAtPublicCallback).toBe(true)
end)

it("returns the stable publication attachment failure and rolls back controllers and registry binding", function()
	local publicRegistrations: number = 0
	Lifecycle.AttachActor = function(_actor: ActorTypes.Actor): (boolean, string?)
		return false, "InvalidPublicationSnapshot:Game.State"
	end
	table.insert(
		connections,
		ActorRuntime.OnActorRegistered:Connect(function(): ()
			publicRegistrations += 1
		end)
	)
	local actor: ActorTypes.Actor?, reason: string? = register()
	expect(actor).toBeNil()
	expect(reason).toBe("InvalidPublicationSnapshot:Game.State")
	expect(publicRegistrations).toBe(0)
	expect(ActorRegistry.GetActorByModel(model)).toBeNil()
	expect(order[#order]).toBe("DestroyController")
end)

it("stops publication before controller destruction on explicit unregister", function()
	local actor: ActorTypes.Actor?, reason: string? = register()
	expect(reason).toBeNil()
	assert(actor ~= nil, "Expected registered Actor")
	order = {}
	local success: boolean, unregisterReason: string? = ActorRuntime.UnregisterActor(actor, "Test")
	expect(success).toBe(true)
	expect(unregisterReason).toBeNil()
	expect(order).toEqual({ "DetachPublication", "DestroyController" })
	expect(ActorRegistry.GetActorByModel(model)).toBeNil()
end)

it("stops publication before controller destruction when the Actor Model disappears", function()
	local actor: ActorTypes.Actor?, reason: string? = register()
	expect(reason).toBeNil()
	assert(actor ~= nil, "Expected registered Actor")
	order = {}
	model:Destroy()
	expect(order).toEqual({ "DetachPublication", "DestroyController" })
	expect(actor.enabled).toBe(false)
end)

it("allows a lifecycle seam call after startup reset without retaining the old runtime", function()
	Server._ResetForTests()
	Lifecycle.AttachActor = originalAttach
	Lifecycle.DetachActor = originalDetach
	local actor: ActorTypes.Actor = require(KRF.server.Actor.ActorEntity).new()
	local attached: boolean, reason: string? = Lifecycle.AttachActor(actor)
	expect(attached).toBe(true)
	expect(reason).toBeNil()
	Lifecycle.DetachActor(actor)
end)
