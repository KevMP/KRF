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

local ActionRegistry = require(KRF.server.Action.ActionRegistry)
local ActionControllerModule = require(KRF.server.Action.ActionController)
local ActorEntity = require(KRF.server.Actor.ActorEntity)

local controllers: { ActionController } = {}

beforeEach(function()
	ActionRegistry._resetForTests()
	controllers = {}
end)

afterEach(function()
	for _, controller: ActionController in controllers do
		controller:Destroy()
	end
	ActionRegistry._resetForTests()
end)

local function loadActions(definitions: { ActionDefinition }): ()
	local loaded: boolean, reason: string? = ActionRegistry.Load(definitions, {}, {})
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
end

local function createController(): (Actor, ActionController)
	local actor: Actor = ActorEntity.new()
	local controller: ActionController = ActionControllerModule.new(actor)
	table.insert(controllers, controller)
	return actor, controller
end

local function action(id: string, autoGrant: boolean?): ActionDefinition
	return { id = id, visibility = "ServerOnly", autoGrant = autoGrant }
end

local function flushEvents(): ()
	task.wait()
	task.wait()
end

it("starts empty when the catalog has no auto-granted Actions", function()
	loadActions({ action("Action.Dodge"), action("Action.Roll") })
	local _actor: Actor, controller: ActionController = createController()
	expect(controller:IsActionGranted("Action.Dodge")).toBe(false)
	expect(controller:GetGrantedActions()).toEqual({})
end)

it("starts with all auto-granted Actions and no synthetic grant events", function()
	loadActions({ action("Action.Dodge", true), action("Action.Roll"), action("Action.Jump", true) })
	local _actor: Actor, controller: ActionController = createController()
	local eventCount: number = 0
	local connection = controller.OnActionGrantChanged:Connect(function()
		eventCount += 1
	end)
	expect(controller:IsActionGranted("Action.Dodge")).toBe(true)
	expect(controller:IsActionGranted("Action.Jump")).toBe(true)
	expect(controller:IsActionGranted("Action.Roll")).toBe(false)
	expect(controller:IsActionGranted("Action.Unknown")).toBe(false)
	expect(controller:GetGrantedActions()).toEqual({ "Action.Dodge", "Action.Jump" })
	flushEvents()
	expect(eventCount).toBe(0)
	connection:Disconnect()
end)

it("grants a source's complete set and returns effective Actions in catalog order", function()
	loadActions({ action("Action.Z"), action("Action.Auto", true), action("Action.A") })
	local _actor: Actor, controller: ActionController = createController()
	local success: boolean, reason: string? = controller:SetGrants("Learned", { "Action.A", "Action.Z" })
	expect(success).toBe(true)
	expect(reason).toBeNil()
	expect(controller:IsActionGranted("Action.A")).toBe(true)
	expect(controller:GetGrantedActions()).toEqual({ "Action.Z", "Action.Auto", "Action.A" })
end)

it("replaces only the named source and keeps another source's overlapping grant", function()
	loadActions({ action("Action.A"), action("Action.B"), action("Action.C") })
	local _actor: Actor, controller: ActionController = createController()
	expect((controller:SetGrants("Learned", { "Action.A", "Action.B" }))).toBe(true)
	expect((controller:SetGrants("Loadout", { "Action.B", "Action.C" }))).toBe(true)
	expect((controller:SetGrants("Learned", { "Action.C" }))).toBe(true)
	expect(controller:IsActionGranted("Action.A")).toBe(false)
	expect(controller:IsActionGranted("Action.B")).toBe(true)
	expect(controller:IsActionGranted("Action.C")).toBe(true)
	expect(controller:GetGrantedActions()).toEqual({ "Action.B", "Action.C" })
end)

it("normalizes duplicate ids and repeated normalized sets without duplicate events", function()
	loadActions({ action("Action.A"), action("Action.B") })
	local _actor: Actor, controller: ActionController = createController()
	local changed: { string } = {}
	local connection = controller.OnActionGrantChanged:Connect(
		function(_eventActor: Actor, actionId: string, granted: boolean)
			table.insert(changed, actionId .. ":" .. tostring(granted))
		end
	)
	expect((controller:SetGrants("Learned", { "Action.B", "Action.A", "Action.A" }))).toBe(true)
	expect(controller:GetGrantedActions()).toEqual({ "Action.A", "Action.B" })
	flushEvents()
	expect(#changed).toBe(2)
	expect((controller:SetGrants("Learned", { "Action.A", "Action.B", "Action.B" }))).toBe(true)
	flushEvents()
	expect(#changed).toBe(2)
	connection:Disconnect()
end)

it("clears one source, revokes only its final grants, and treats absent clears as no-ops", function()
	loadActions({ action("Action.A"), action("Action.B") })
	local _actor: Actor, controller: ActionController = createController()
	local eventCount: number = 0
	local connection = controller.OnActionGrantChanged:Connect(function()
		eventCount += 1
	end)
	expect((controller:SetGrants("First", { "Action.A", "Action.B" }))).toBe(true)
	expect((controller:SetGrants("Second", { "Action.B" }))).toBe(true)
	expect((controller:SetGrants("First", {}))).toBe(true)
	expect(controller:GetGrantedActions()).toEqual({ "Action.B" })
	flushEvents()
	expect(eventCount).toBe(3)
	expect((controller:SetGrants("First", {}))).toBe(true)
	expect((controller:SetGrants("Absent", {}))).toBe(true)
	flushEvents()
	expect(eventCount).toBe(3)
	expect((controller:SetGrants("Second", {}))).toBe(true)
	expect(controller:GetGrantedActions()).toEqual({})
	flushEvents()
	expect(eventCount).toBe(4)
	connection:Disconnect()
end)

it("never revokes an auto-grant through redundant explicit sources", function()
	loadActions({ action("Action.Auto", true) })
	local _actor: Actor, controller: ActionController = createController()
	local eventCount: number = 0
	local connection = controller.OnActionGrantChanged:Connect(function()
		eventCount += 1
	end)
	expect((controller:SetGrants("First", { "Action.Auto" }))).toBe(true)
	expect((controller:SetGrants("Second", { "Action.Auto" }))).toBe(true)
	expect((controller:SetGrants("First", {}))).toBe(true)
	expect((controller:SetGrants("Second", {}))).toBe(true)
	expect(controller:GetGrantedActions()).toEqual({ "Action.Auto" })
	flushEvents()
	expect(eventCount).toBe(0)
	connection:Disconnect()
end)

it("commits a complete replacement before notifying observers of effective transitions", function()
	loadActions({ action("Action.A"), action("Action.B"), action("Action.C") })
	local actor: Actor, controller: ActionController = createController()
	expect((controller:SetGrants("Learned", { "Action.A" }))).toBe(true)
	local observed: { [string]: boolean } = {}
	local observedLists: { { string } } = {}
	local observedActors: { Actor } = {}
	local eventCount: number = 0
	local connection = controller.OnActionGrantChanged:Connect(
		function(eventActor: Actor, actionId: string, isGranted: boolean)
			table.insert(observedActors, eventActor)
			observed[actionId] = isGranted
			table.insert(observedLists, controller:GetGrantedActions())
			eventCount += 1
		end
	)
	expect((controller:SetGrants("Learned", { "Action.C", "Action.B" }))).toBe(true)
	flushEvents()
	expect(eventCount).toBe(3)
	expect(observed).toEqual({ ["Action.A"] = false, ["Action.B"] = true, ["Action.C"] = true })
	for index: number = 1, 3 do
		expect(observedActors[index]).toBe(actor)
		expect(observedLists[index]).toEqual({ "Action.B", "Action.C" })
	end
	connection:Disconnect()
end)

it("does not expose mutable internal grant state through the returned Action list", function()
	loadActions({ action("Action.A") })
	local _actor: Actor, controller: ActionController = createController()
	expect((controller:SetGrants("Learned", { "Action.A" }))).toBe(true)
	local granted: { string } = controller:GetGrantedActions()
	pcall(function()
		table.clear(granted)
		table.insert(granted, "Action.Unknown")
	end)
	expect(controller:IsActionGranted("Action.A")).toBe(true)
	expect(controller:IsActionGranted("Action.Unknown")).toBe(false)
	expect(controller:GetGrantedActions()).toEqual({ "Action.A" })
end)

it("destroys its owned event without emitting synthetic grant revocations", function()
	loadActions({ action("Action.Auto", true), action("Action.Manual") })
	local _actor: Actor, controller: ActionController = createController()
	expect((controller:SetGrants("Learned", { "Action.Manual" }))).toBe(true)
	local eventCount: number = 0
	controller.OnActionGrantChanged:Connect(function()
		eventCount += 1
	end)
	controller:Destroy()
	flushEvents()
	expect(eventCount).toBe(0)
	expect(function()
		controller.OnActionGrantChanged:Connect(function() end)
	end).toThrow()
	controller:Destroy()
end)
