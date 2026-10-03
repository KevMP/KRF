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
type Actor = ActorTypes.Actor

local ActionRegistry = require(KRF.server.Action.ActionRegistry)
local ActionControllerModule = require(KRF.server.Action.ActionController)
local ActorEntity = require(KRF.server.Actor.ActorEntity)

local controllers: { any } = {}

beforeEach(function()
	ActionRegistry._resetForTests()
	controllers = {}
end)

afterEach(function()
	for _, controller: any in controllers do
		controller:Destroy()
	end
	ActionRegistry._resetForTests()
end)

local function loadActions(definitions: { ActionDefinition }): ()
	local loaded: boolean, reason: string? = ActionRegistry.Load(definitions, {}, {})
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
end

local function createController(): (Actor, any)
	local actor: Actor = ActorEntity.new()
	actor.enabled = true
	local controller: any = ActionControllerModule.new(actor)
	table.insert(controllers, controller)
	return actor, controller
end

it("accepts a granted Action and allocates one positive sequence id", function()
	loadActions({ { id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true } })
	local _actor: Actor, controller: any = createController()
	local result: any = controller:RequestAction("Action.Dodge")
	expect(result.accepted).toBe(true)
	expect(type(result.sequenceId)).toBe("number")
	expect(result.sequenceId > 0).toBe(true)
	expect(result.reason).toBeNil()
end)

it("rejects invalid, unknown, and ungranted ids without consuming a sequence id", function()
	loadActions({
		{ id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true },
		{ id = "Action.Roll", visibility = "ServerOnly" },
	})
	local _actor: Actor, controller: any = createController()
	for _, actionId: any in { 12, {}, "", "Action.Unknown", "Action.Roll" } :: { any } do
		local result: any = controller:RequestAction(actionId)
		expect(result.accepted).toBe(false)
		expect(type(result.reason)).toBe("string")
		expect(result.reason).never.toBe("")
		expect(result.sequenceId).toBeNil()
	end
	local accepted: any = controller:RequestAction("Action.Dodge")
	expect(accepted).toEqual({ accepted = true, sequenceId = 1 })
end)

it("rejects requests while the Actor is disabled or the controller is destroyed", function()
	loadActions({ { id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true } })
	local actor: Actor, controller: any = createController()
	actor.enabled = false
	local disabled: any = controller:RequestAction("Action.Dodge")
	expect(disabled.accepted).toBe(false)
	expect(type(disabled.reason)).toBe("string")
	actor.enabled = true
	expect(controller:RequestAction("Action.Dodge")).toEqual({ accepted = true, sequenceId = 1 })
	controller:Destroy()
	local destroyed: any = controller:RequestAction("Action.Dodge")
	expect(destroyed.accepted).toBe(false)
	expect(destroyed.reason).toBe("ActionControllerDestroyed")
end)

it("allocates sequence ids in commit order and allows concurrent same-id instances", function()
	loadActions({ { id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true } })
	local _actor: Actor, controller: any = createController()
	local first: any = controller:RequestAction("Action.Dodge")
	local second: any = controller:RequestAction("Action.Dodge")
	expect(first).toEqual({ accepted = true, sequenceId = 1 })
	expect(second).toEqual({ accepted = true, sequenceId = 2 })
	expect(controller:EndAction(first.sequenceId)).toBe(true)
	expect(controller:EndAction(second.sequenceId)).toBe(true)
	expect(controller:RequestAction("Action.Dodge")).toEqual({ accepted = true, sequenceId = 3 })
end)

it("scopes sequence ids to each Actor's controller", function()
	loadActions({ { id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true } })
	local _firstActor: Actor, firstController: any = createController()
	local _secondActor: Actor, secondController: any = createController()
	expect(firstController:RequestAction("Action.Dodge")).toEqual({ accepted = true, sequenceId = 1 })
	expect(secondController:RequestAction("Action.Dodge")).toEqual({ accepted = true, sequenceId = 1 })
end)

it("passes a read-only pre-accept context with the original opaque parameters", function()
	local parameters: { [any]: any } = {}
	parameters.self = parameters
	local actor: Actor? = nil
	local observed: any = nil
	loadActions({
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			onCanStart = function(context: any): boolean
				observed = context
				return true
			end,
		},
	})
	local controller: any
	actor, controller = createController()
	expect(controller:RequestAction("Action.Dodge", parameters).accepted).toBe(true)
	expect(observed.actor).toBe(actor)
	expect(observed.actionId).toBe("Action.Dodge")
	expect(observed.parameters).toBe(parameters)
	expect(table.isfrozen(observed)).toBe(true)
	expect(rawget(observed, "sequenceId")).toBeNil()
	expect(function()
		observed.actionId = "Action.Other"
	end).toThrow()
end)

it("preserves a custom onCanStart rejection and consumes no id", function()
	local allow: boolean = false
	loadActions({
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			onCanStart = function(): (boolean, string?)
				if not allow then
					return false, "GameCooldown"
				end
				return true
			end,
		},
	})
	local _actor: Actor, controller: any = createController()
	expect(controller:RequestAction("Action.Dodge")).toEqual({ accepted = false, reason = "GameCooldown" })
	allow = true
	expect(controller:RequestAction("Action.Dodge")).toEqual({ accepted = true, sequenceId = 1 })
end)

it("maps onCanStart false without a usable reason to one stable framework reason", function()
	loadActions({
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			onCanStart = function(): boolean
				return false
			end,
		},
	})
	local _actor: Actor, controller: any = createController()
	local first: any = controller:RequestAction("Action.Dodge")
	local second: any = controller:RequestAction("Action.Dodge")
	expect(first.accepted).toBe(false)
	expect(type(first.reason)).toBe("string")
	expect(first.reason).never.toBe("")
	expect(second.reason).toBe(first.reason)
end)

it("rejects an onCanStart error or invalid result without activating an instance", function()
	for _, callback: any in
		{
			function(): boolean
				error("decision boom")
			end,
			function(): any
				return "yes"
			end,
		} :: { any }
	do
		loadActions({ { id = "Action.Dodge", visibility = "ServerOnly", autoGrant = true, onCanStart = callback } })
		local _actor: Actor, controller: any = createController()
		local rejected: any = controller:RequestAction("Action.Dodge")
		expect(rejected.accepted).toBe(false)
		expect(type(rejected.reason)).toBe("string")
		expect(rejected.sequenceId).toBeNil()
		controller:Destroy()
		ActionRegistry._resetForTests()
	end
end)

it("rejects a yielding onCanStart without accepting or allocating an instance", function()
	loadActions({
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			onCanStart = function(): boolean
				task.wait()
				return true
			end,
		},
	})
	local _actor: Actor, controller: any = createController()
	local rejected: any = controller:RequestAction("Action.Dodge")
	expect(rejected.accepted).toBe(false)
	expect(type(rejected.reason)).toBe("string")
	expect(rejected.sequenceId).toBeNil()
end)

it("revalidates a grant revoked by onCanStart before committing", function()
	local controller: any = nil
	local revoked: boolean = false
	loadActions({
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			onCanStart = function(): boolean
				revoked = controller:SetGrants("Learned", {})
				return true
			end,
		},
	})
	local _actor: Actor
	_actor, controller = createController()
	expect(controller:SetGrants("Learned", { "Action.Dodge" })).toBe(true)
	local rejected: any = controller:RequestAction("Action.Dodge")
	expect(revoked).toBe(true)
	expect(rejected.accepted).toBe(false)
	expect(type(rejected.reason)).toBe("string")
	expect(controller:IsActionGranted("Action.Dodge")).toBe(false)
	expect(rejected.sequenceId).toBeNil()
end)

it("revalidates Actor and controller availability after onCanStart", function()
	for _, invalidate: string in { "disable", "destroy" } do
		local actor: Actor? = nil
		local controller: any = nil
		loadActions({
			{
				id = "Action.Dodge",
				visibility = "ServerOnly",
				autoGrant = true,
				onCanStart = function(): boolean
					if invalidate == "disable" then
						(actor :: Actor).enabled = false
					else
						controller:Destroy()
					end
					return true
				end,
			},
		})
		actor, controller = createController()
		local rejected: any = controller:RequestAction("Action.Dodge")
		expect(rejected.accepted).toBe(false)
		expect(rejected.sequenceId).toBeNil()
		ActionRegistry._resetForTests()
	end
end)

it("assigns nested requests ids in actual commit order", function()
	local controller: any = nil
	local nested: any = nil
	local entering: boolean = false
	loadActions({
		{
			id = "Action.Dodge",
			visibility = "ServerOnly",
			autoGrant = true,
			onCanStart = function(): boolean
				if not entering then
					entering = true
					nested = controller:RequestAction("Action.Dodge")
				end
				return true
			end,
		},
	})
	local _actor: Actor
	_actor, controller = createController()
	local outer: any = controller:RequestAction("Action.Dodge")
	expect(nested).toEqual({ accepted = true, sequenceId = 1 })
	expect(outer).toEqual({ accepted = true, sequenceId = 2 })
end)
