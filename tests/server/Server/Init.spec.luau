--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach

local ActorTypes: any = require(KRF.server.Actor.types)
local ControllerTypes: any = require(KRF.server.Controller.types)
local TagTypes: any = require(KRF.server.Tags.types)
local ResourceTypes: any = require(KRF.server.Resource.types)
local ServerTypes: any = require(KRF.server.types)

type Actor = ActorTypes.Actor
type ActorRuntime = ActorTypes.ActorRuntime
type ActorRegistry = ActorTypes.ActorRegistry
type Controller = ActorTypes.Controller
type ControllerDef = ControllerTypes.ControllerDef
type ControllerRegistry = ControllerTypes.ControllerRegistry
type TagDefinition = TagTypes.TagDefinition
type TagRegistry = TagTypes.TagRegistry
type ResourceDefinition = ResourceTypes.ResourceDefinition
type LoadedResourceDefinition = ResourceTypes.LoadedResourceDefinition
type ResourceRegistry = ResourceTypes.ResourceRegistry
type StartupFailure = ServerTypes.StartupFailure

local Server = require(KRF.server)
local Init = Server.Init
local Runtime: ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Registry: ActorRegistry = require(KRF.server.Actor.ActorRegistry)
local Controllers: ControllerRegistry = require(KRF.server.Controller.ControllerRegistry)
local Tags: TagRegistry = require(KRF.server.Tags.TagRegistry)
local Resources: ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)

local testModels: { Model } = {}
local testConnections: { any } = {}
local testActors: { Actor } = {}

beforeEach(function()
	Server._ResetForTests()
	testModels = {}
	testConnections = {}
	testActors = {}
end)

afterEach(function()
	for _, connection: any in testConnections do
		connection:Disconnect()
	end

	for _, actor: Actor in testActors do
		if Registry.GetActorById(actor:GetId()) ~= nil then
			Runtime.UnregisterActor(actor, "TestCleanup")
		end
	end

	for _, model: Model in testModels do
		model:Destroy()
	end

	Server._ResetForTests()
end)

local function createModel(): Model
	local model: Model = Instance.new("Model")
	model.Parent = workspace
	table.insert(testModels, model)
	return model
end

local function createControllerDefinition(key: string, dependsOn: { string }?): ControllerDef
	local definition: ControllerDef = {
		key = key,
		factory = function(_actor: Actor): Controller
			return { Destroy = function() end }
		end,
	}

	if dependsOn ~= nil then
		definition.dependsOn = dependsOn
	end

	return definition
end

local function createTagDefinition(id: string): TagDefinition
	return {
		id = id,
		duplicateBehavior = "Ignore",
		visibility = "ServerOnly",
	}
end

local function createResourceDefinition(id: string): ResourceDefinition
	return {
		id = id,
		max = { value = 100 },
		visibility = "ServerOnly",
	}
end

local function expectFailure(failure: StartupFailure?, system: string, reason: string)
	expect(failure).never.toBeNil()

	local startupFailure: StartupFailure = failure :: StartupFailure
	expect(startupFailure.system).toBe(system)
	expect(startupFailure.reason).toBe(reason)
end

it("KRF.Server.Init publishes valid controller, tag, and resource catalogs together", function()
	local started: boolean, failure: StartupFailure? = Init({
		controllers = {
			createControllerDefinition("Game.Root", { "ResourceController" }),
			createControllerDefinition("Game.Dependent", { "Game.Root" }),
		},
		tags = { createTagDefinition("Game.Burning") },
		resources = { createResourceDefinition("Game.Stamina") },
	})

	expect(started).toBe(true)
	expect(failure).toBeNil()

	local rootController = Controllers.Get("Game.Root")
	local tagDefinition = Tags.Get("Game.Burning")
	local resourceDefinition = Resources.Get("Game.Stamina")
	expect(rootController).never.toBeNil()
	expect(tagDefinition).never.toBeNil()
	expect(resourceDefinition).never.toBeNil()
	expect((rootController :: ControllerDef).key).toBe("Game.Root")
	expect(Controllers.Get("TagController")).never.toBeNil()
	expect(Controllers.Get("PropertyController")).never.toBeNil()
	expect(Controllers.Get("ResourceController")).never.toBeNil()
	expect((tagDefinition :: TagDefinition).id).toBe("Game.Burning")
	expect((resourceDefinition :: LoadedResourceDefinition).id).toBe("Game.Stamina")
end)

it("KRF.Server.Init loads built-in controllers when game catalogs are omitted", function()
	local started: boolean, failure: StartupFailure? = Init({})

	expect(started).toBe(true)
	expect(failure).toBeNil()
	expect(Controllers.GetAutoAttachKeys()).toEqual({ "TagController", "PropertyController", "ResourceController" })
	expect(Tags.IsLoaded()).toBe(true)
	expect(#Tags.GetAll()).toBe(0)
	expect(Resources.IsLoaded()).toBe(true)
	expect(#Resources.GetAll()).toBe(0)
end)

it("KRF.Server.Init rejects game definitions that duplicate a built-in controller", function()
	local started: boolean, failure: StartupFailure? = Init({
		controllers = { createControllerDefinition("TagController", nil) },
	})

	expect(started).toBe(false)
	expectFailure(failure, "Controller", "DuplicateControllerKey")
	expect(Controllers.IsLoaded()).toBe(false)
	expect(Tags.IsLoaded()).toBe(false)
	expect(Resources.IsLoaded()).toBe(false)
end)

it("KRF.Server.Init rejects invalid controller catalogs without publishing any system", function()
	local started: boolean, failure: StartupFailure? = Init({
		controllers = {
			createControllerDefinition("Game.Duplicate", nil),
			createControllerDefinition("Game.Duplicate", nil),
		},
	})

	expect(started).toBe(false)
	expectFailure(failure, "Controller", "DuplicateControllerKey")
	expect(Controllers.Get("Game.Duplicate")).toBeNil()
	expect(Tags.IsLoaded()).toBe(false)
	expect(Resources.IsLoaded()).toBe(false)
end)

it("KRF.Server.Init leaves every catalog unpublished when tag preparation fails after controllers", function()
	local invalidTagDefinition: TagDefinition = createTagDefinition("Game.InvalidTag");
	(invalidTagDefinition :: any).visibility = "Everyone"

	local started: boolean, failure: StartupFailure? = Init({
		controllers = { createControllerDefinition("Game.ValidController", nil) },
		tags = { invalidTagDefinition },
	})

	expect(started).toBe(false)
	expectFailure(failure, "Tag", "TagVisibilityInvalid")
	expect(Controllers.Get("Game.ValidController")).toBeNil()
	expect(Tags.IsLoaded()).toBe(false)
	expect(Resources.IsLoaded()).toBe(false)
end)

it("KRF.Server.Init leaves every catalog unpublished when resource preparation fails last", function()
	local invalidResourceDefinition: ResourceDefinition = createResourceDefinition("Game.InvalidResource");
	(invalidResourceDefinition :: any).visibility = "Everyone"

	local started: boolean, failure: StartupFailure? = Init({
		controllers = { createControllerDefinition("Game.ValidController", nil) },
		tags = { createTagDefinition("Game.ValidTag") },
		resources = { invalidResourceDefinition },
	})

	expect(started).toBe(false)
	expectFailure(failure, "Resource", "ResourceVisibilityInvalid")
	expect(Controllers.Get("Game.ValidController")).toBeNil()
	expect(Tags.IsLoaded()).toBe(false)
	expect(Tags.Get("Game.ValidTag")).toBeNil()
	expect(Resources.IsLoaded()).toBe(false)
	expect(Resources.Get("Game.InvalidResource")).toBeNil()
end)

it("KRF.Server.Init rejects missing controller dependencies during initialization", function()
	local started: boolean, failure: StartupFailure? = Init({
		controllers = { createControllerDefinition("Game.NeedsMissing", { "Game.Missing" }) },
	})

	expect(started).toBe(false)
	expectFailure(failure, "Controller", "MissingDependency:Game.NeedsMissing->Game.Missing")
	expect(Controllers.Get("Game.NeedsMissing")).toBeNil()
end)

it("KRF.Server.Init rejects controller dependency cycles during initialization", function()
	local started: boolean, failure: StartupFailure? = Init({
		controllers = {
			createControllerDefinition("Game.A", { "Game.B" }),
			createControllerDefinition("Game.B", { "Game.A" }),
		},
	})

	expect(started).toBe(false)
	expectFailure(failure, "Controller", "CyclicDependency")
	expect(Controllers.Get("Game.A")).toBeNil()
	expect(Controllers.Get("Game.B")).toBeNil()
end)

it("KRF.Server.Init preserves catalog order between unrelated controllers", function()
	local attachmentOrder: { string } = {}
	local firstController: ControllerDef = {
		key = "Game.First",
		factory = function(_actor: Actor): Controller
			table.insert(attachmentOrder, "Game.First")
			return { Destroy = function() end }
		end,
	}
	local secondController: ControllerDef = {
		key = "Game.Second",
		factory = function(_actor: Actor): Controller
			table.insert(attachmentOrder, "Game.Second")
			return { Destroy = function() end }
		end,
	}

	local started: boolean, failure: StartupFailure? = Init({
		controllers = { firstController, secondController },
	})
	expect(started).toBe(true)
	expect(failure).toBeNil()

	local actor: Actor?, registrationReason: string? = Runtime.RegisterActor(createModel())
	if actor ~= nil then
		table.insert(testActors, actor)
	end

	expect(registrationReason).toBeNil()
	expect(actor).never.toBeNil()
	expect(attachmentOrder).toEqual({ "Game.First", "Game.Second" })
end)

it("Actors registered at different times receive the same dependency-ordered auto-attach set", function()
	local attachmentOrder: { string } = {}
	local function definition(key: string, dependsOn: { string }?, autoAttach: boolean?): ControllerDef
		return {
			key = key,
			dependsOn = dependsOn,
			autoAttach = autoAttach,
			factory = function(_actor: Actor): Controller
				table.insert(attachmentOrder, key)
				return { Destroy = function() end }
			end,
		}
	end

	local started: boolean, failure: StartupFailure? = Init({
		controllers = {
			definition("Game.Dependent", { "Game.Root" }, nil),
			definition("Game.Disabled", nil, false),
			definition("Game.Root", nil, nil),
		},
	})
	expect(started).toBe(true)
	expect(failure).toBeNil()

	local firstActor: Actor?, firstReason: string? = Runtime.RegisterActor(createModel())
	local secondActor: Actor?, secondReason: string? = Runtime.RegisterActor(createModel())
	if firstActor ~= nil then
		table.insert(testActors, firstActor)
	end
	if secondActor ~= nil then
		table.insert(testActors, secondActor)
	end

	expect(firstReason).toBeNil()
	expect(secondReason).toBeNil()
	expect(firstActor).never.toBeNil()
	expect(secondActor).never.toBeNil()
	expect(attachmentOrder).toEqual({ "Game.Root", "Game.Dependent", "Game.Root", "Game.Dependent" })
end)

it("Actor registration before KRF.Server.Init leaves no lifecycle residue", function()
	local registrationEvents: number = 0
	local connection = Runtime.OnActorRegistered:Connect(function(_actor: Actor)
		registrationEvents += 1
	end)
	table.insert(testConnections, connection)

	local model: Model = createModel()
	local actor: Actor?, reason: string? = Runtime.RegisterActor(model)

	expect(actor).toBeNil()
	expect(reason).toBe("ControllerDefinitionsNotLoaded")
	expect(Registry.GetActorByModel(model)).toBeNil()
	expect(registrationEvents).toBe(0)
end)

it("Loading ControllerRegistry directly does not unlock Actor registration", function()
	local loaded: boolean, loadReason: string? = Controllers.Load({})
	expect(loaded).toBe(true)
	expect(loadReason).toBeNil()

	local registrationEvents: number = 0
	local connection = Runtime.OnActorRegistered:Connect(function(_actor: Actor)
		registrationEvents += 1
	end)
	table.insert(testConnections, connection)

	local model: Model = createModel()
	local actor: Actor?, reason: string? = Runtime.RegisterActor(model)

	expect(actor).toBeNil()
	expect(reason).toBe("ControllerDefinitionsNotLoaded")
	expect(Registry.GetActorByModel(model)).toBeNil()
	expect(registrationEvents).toBe(0)
	expect(Tags.IsLoaded()).toBe(false)
	expect(Resources.IsLoaded()).toBe(false)
end)

it("Actor registration after successful KRF.Server.Init succeeds", function()
	local started: boolean, failure: StartupFailure? = Init({})
	expect(started).toBe(true)
	expect(failure).toBeNil()

	local model: Model = createModel()
	local actor: Actor?, reason: string? = Runtime.RegisterActor(model)
	if actor ~= nil then
		table.insert(testActors, actor)
	end

	expect(reason).toBeNil()
	expect(actor).never.toBeNil()

	local registeredActor: Actor = actor :: Actor
	expect(registeredActor.enabled).toBe(true)
	expect(Registry.GetActorByModel(model)).toBe(registeredActor)
	expect(registeredActor:GetController("TagController")).never.toBeNil()
	expect(registeredActor:GetController("PropertyController")).never.toBeNil()
	expect(registeredActor:GetController("ResourceController")).never.toBeNil()
end)

it("Actor registration after failed KRF.Server.Init remains unavailable without lifecycle residue", function()
	local started: boolean, failure: StartupFailure? = Init({
		controllers = { createControllerDefinition("Game.NeedsMissing", { "Game.Missing" }) },
	})
	expect(started).toBe(false)
	expectFailure(failure, "Controller", "MissingDependency:Game.NeedsMissing->Game.Missing")

	local registrationEvents: number = 0
	local connection = Runtime.OnActorRegistered:Connect(function(_actor: Actor)
		registrationEvents += 1
	end)
	table.insert(testConnections, connection)

	local model: Model = createModel()
	local actor: Actor?, reason: string? = Runtime.RegisterActor(model)

	expect(actor).toBeNil()
	expect(reason).never.toBeNil()
	expect(Registry.GetActorByModel(model)).toBeNil()
	expect(registrationEvents).toBe(0)
end)

it("KRF.Server.Init rejects later initialization after success", function()
	local started: boolean, failure: StartupFailure? = Init({})
	expect(started).toBe(true)
	expect(failure).toBeNil()

	local repeatedStarted: boolean, repeatedFailure: StartupFailure? = Init({})
	expect(repeatedStarted).toBe(false)
	expect(repeatedFailure).never.toBeNil()
	expect((repeatedFailure :: StartupFailure).system).toBe("Server")
end)

it("KRF.Server.Init rejects later initialization after failure", function()
	local started: boolean, failure: StartupFailure? = Init({
		controllers = { createControllerDefinition("Game.NeedsMissing", { "Game.Missing" }) },
	})
	expect(started).toBe(false)
	expectFailure(failure, "Controller", "MissingDependency:Game.NeedsMissing->Game.Missing")

	local repeatedStarted: boolean, repeatedFailure: StartupFailure? = Init({})
	expect(repeatedStarted).toBe(false)
	expect(repeatedFailure).never.toBeNil()
	expect((repeatedFailure :: StartupFailure).system).toBe("Server")
end)
