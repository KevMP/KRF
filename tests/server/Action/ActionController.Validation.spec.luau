--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach

local ActionTypes = require(KRF.server.Action.types)
type ActionController = ActionTypes.ActionController

local ActionRegistry = require(KRF.server.Action.ActionRegistry)
local ActionControllerModule = require(KRF.server.Action.ActionController)
local ActorEntity = require(KRF.server.Actor.ActorEntity)

local controllers: { ActionController } = {}

beforeEach(function()
	ActionRegistry._resetForTests()
	controllers = {}
	local loaded: boolean, reason: string? = ActionRegistry.Load({
		function()
			return { id = "Action.A", visibility = "ServerOnly" }
		end,
		function()
			return { id = "Action.B", visibility = "ServerOnly" }
		end,
		function()
			return { id = "Action.C", visibility = "ServerOnly" }
		end,
	}, {}, {})
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
end)

afterEach(function()
	for _, controller: ActionController in controllers do
		controller:Destroy()
	end
	ActionRegistry._resetForTests()
end)

local function createController(): ActionController
	local controller: ActionController = ActionControllerModule.new(ActorEntity.new())
	table.insert(controllers, controller)
	return controller
end

it("rejects non-string and empty source ids without changing grants or emitting events", function()
	local controller: ActionController = createController()
	expect((controller:SetGrants("Learned", { "Action.A" }))).toBe(true)
	local eventCount: number = 0
	local connection = controller.OnActionGrantChanged:Connect(function()
		eventCount += 1
	end)
	for _, invalidSource: any in { 12, {}, "" } :: { any } do
		local success: boolean, reason: string? = controller:SetGrants(invalidSource, { "Action.B" })
		expect(success).toBe(false)
		expect(type(reason)).toBe("string")
		expect(reason).never.toBe("")
		expect(controller:GetGrantedActions()).toEqual({ "Action.A" })
	end
	task.wait()
	task.wait()
	expect(eventCount).toBe(0)
	connection:Disconnect()
end)

it("treats source ids as exact, case-sensitive, opaque keys", function()
	local controller: ActionController = createController()
	expect((controller:SetGrants("loadout:1", { "Action.A" }))).toBe(true)
	expect((controller:SetGrants("Loadout:1", { "Action.B" }))).toBe(true)
	expect((controller:SetGrants("loadout:1", {}))).toBe(true)
	expect(controller:GetGrantedActions()).toEqual({ "Action.B" })
end)

it("rejects non-array grant input and leaves the previous source contribution intact", function()
	local controller: ActionController = createController()
	expect((controller:SetGrants("Learned", { "Action.A" }))).toBe(true)
	for _, invalidList: any in { false, "Action.B", { ["Action.B"] = true }, { [2] = "Action.B" } } :: { any } do
		local success: boolean, reason: string? = controller:SetGrants("Learned", invalidList)
		expect(success).toBe(false)
		expect(type(reason)).toBe("string")
		expect(controller:GetGrantedActions()).toEqual({ "Action.A" })
	end
end)

it("rejects non-string, empty, and unknown Action ids atomically", function()
	local controller: ActionController = createController()
	expect((controller:SetGrants("Learned", { "Action.A" }))).toBe(true)
	local eventCount: number = 0
	local connection = controller.OnActionGrantChanged:Connect(function()
		eventCount += 1
	end)
	for _, invalidAction: any in { 5, "", "Action.Unknown" } :: { any } do
		local success: boolean, reason: string? = controller:SetGrants("Learned", { "Action.B", invalidAction })
		expect(success).toBe(false)
		expect(type(reason)).toBe("string")
		expect(reason).never.toBe("")
		expect(controller:GetGrantedActions()).toEqual({ "Action.A" })
	end
	task.wait()
	task.wait()
	expect(eventCount).toBe(0)
	connection:Disconnect()
end)

it("preserves other sources and the old source set after failed reconciliation", function()
	local controller: ActionController = createController()
	expect((controller:SetGrants("First", { "Action.A" }))).toBe(true)
	expect((controller:SetGrants("Second", { "Action.B" }))).toBe(true)
	local success: boolean, reason: string? = controller:SetGrants("First", { "Action.C", "Action.Unknown" })
	expect(success).toBe(false)
	expect(type(reason)).toBe("string")
	expect(controller:GetGrantedActions()).toEqual({ "Action.A", "Action.B" })
	expect((controller:SetGrants("Second", {}))).toBe(true)
	expect(controller:GetGrantedActions()).toEqual({ "Action.A" })
end)

it("returns a stable reason for repeated failures of the same invalid input", function()
	local controller: ActionController = createController()
	local firstSuccess: boolean, firstReason: string? = controller:SetGrants("Learned", { "Action.Unknown" })
	local secondSuccess: boolean, secondReason: string? = controller:SetGrants("Learned", { "Action.Unknown" })
	expect(firstSuccess).toBe(false)
	expect(secondSuccess).toBe(false)
	expect(type(firstReason)).toBe("string")
	expect(firstReason).toBe(secondReason)
	expect(controller:GetGrantedActions()).toEqual({})
end)
