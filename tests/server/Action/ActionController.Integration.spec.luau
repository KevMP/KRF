--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach

local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
type ActionDefinition = ActionTypes.ActionDefinition
type ActionController = ActionTypes.ActionController
type Actor = ActorTypes.Actor

local Server = require(KRF.server)
local ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local ActorRegistry = require(KRF.server.Actor.ActorRegistry)
local ControllerRegistry = require(KRF.server.Controller.ControllerRegistry)

local models: { Model } = {}
local actors: { Actor } = {}

beforeEach(function()
	Server._ResetForTests()
	models = {}
	actors = {}
end)

afterEach(function()
	for _, actor: Actor in actors do
		if ActorRegistry.GetActorById(actor:GetId()) ~= nil then
			ActorRuntime.UnregisterActor(actor, "TestCleanup")
		end
	end
	for _, model: Model in models do
		model:Destroy()
	end
	Server._ResetForTests()
end)

local function registerActor(): (Actor, ActionController)
	local model: Model = Instance.new("Model")
	model.Parent = workspace
	table.insert(models, model)
	local actor: Actor?, reason: string? = ActorRuntime.RegisterActor(model)
	expect(reason).toBeNil()
	expect(actor).never.toBeNil()
	local registeredActor: Actor = actor :: Actor
	table.insert(actors, registeredActor)
	local controller: ActionController? = registeredActor:GetController("ActionController") :: ActionController?
	expect(controller).never.toBeNil()
	return registeredActor, controller :: ActionController
end

it("auto-attaches one KRF-owned ActionController after successful startup without a speculative dependency", function()
	local started: boolean, failure = Server.Init({ actions = {} })
	expect(started).toBe(true)
	expect(failure).toBeNil()
	local definition = ControllerRegistry.Get("ActionController")
	expect(definition).never.toBeNil()
	expect((definition :: any).dependsOn).toBeNil()
	expect((definition :: any).autoAttach).never.toBe(false)
	local _actor: Actor, controller: ActionController = registerActor()
	expect(controller:GetGrantedActions()).toEqual({})
end)

it("gives each Actor independent source grants while sharing the loaded auto-grant baseline", function()
	local started: boolean, failure = Server.Init({
		actions = {
			function(): ActionDefinition
				return { id = "Action.Auto", visibility = "ServerOnly", autoGrant = true }
			end,
			function(): ActionDefinition
				return { id = "Action.Manual", visibility = "ServerOnly" }
			end,
		},
	})
	expect(started).toBe(true)
	expect(failure).toBeNil()
	local _firstActor: Actor, firstController: ActionController = registerActor()
	local _secondActor: Actor, secondController: ActionController = registerActor()
	expect(firstController:GetGrantedActions()).toEqual({ "Action.Auto" })
	expect(secondController:GetGrantedActions()).toEqual({ "Action.Auto" })
	expect((firstController:SetGrants("Learned", { "Action.Manual" }))).toBe(true)
	expect(firstController:GetGrantedActions()).toEqual({ "Action.Auto", "Action.Manual" })
	expect(secondController:GetGrantedActions()).toEqual({ "Action.Auto" })
	expect((secondController:SetGrants("Learned", { "Action.Manual" }))).toBe(true)
	expect((firstController:SetGrants("Learned", {}))).toBe(true)
	expect(firstController:GetGrantedActions()).toEqual({ "Action.Auto" })
	expect(secondController:GetGrantedActions()).toEqual({ "Action.Auto", "Action.Manual" })
end)
