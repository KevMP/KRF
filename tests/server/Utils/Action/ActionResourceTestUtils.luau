--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local ResourceTypes = require(KRF.server.Resource.types)
local PropertyTypes = require(KRF.server.Property.types)
local TagTypes = require(KRF.server.Tags.types)
local Server = require(KRF.server)
local ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local ActorRegistry = require(KRF.server.Actor.ActorRegistry)
local TagControllerModule = require(KRF.server.Tags.TagController)
local ResourceControllerModule = require(KRF.server.Resource.ResourceController)
local ActionControllerUpdates = require(KRF.server.Action.utils.ActionControllerUpdates)

type Actor = ActorTypes.Actor
local actors: { Actor } = {}
local models: { Model } = {}
local ActionResourceTestUtils = {}

function ActionResourceTestUtils.reset(): ()
	Server._ResetForTests()
	TagControllerModule._setAutomaticSteppingEnabledForTests(false)
	ResourceControllerModule._setAutomaticSteppingEnabledForTests(false)
	ActionControllerUpdates._setAutomaticSteppingEnabledForTests(false)
	actors = {}
	models = {}
end

function ActionResourceTestUtils.cleanup(): ()
	for _, actor: Actor in actors do
		if ActorRegistry.GetActorById(actor:GetId()) ~= nil then
			ActorRuntime.UnregisterActor(actor, "TestCleanup")
		end
	end
	for _, model: Model in models do
		model:Destroy()
	end
	ActionControllerUpdates._setClockForTests(nil)
	ActionControllerUpdates._setAutomaticSteppingEnabledForTests(true)
	ResourceControllerModule._setAutomaticSteppingEnabledForTests(true)
	TagControllerModule._setAutomaticSteppingEnabledForTests(true)
	Server._ResetForTests()
end

function ActionResourceTestUtils.initialize(
	definitions: { ActionTypes.ActionDefinition },
	resources: { ResourceTypes.ResourceDefinition },
	tags: { TagTypes.TagDefinition }?
): ()
	local factories: { ActionTypes.ActionFactory } = {}
	for _, definition: ActionTypes.ActionDefinition in definitions do
		local source: ActionTypes.ActionDefinition = definition
		table.insert(factories, function(): ActionTypes.ActionDefinition
			return table.clone(source)
		end)
	end
	local started: boolean, failure = Server.Init({ actions = factories, resources = resources, tags = tags or {} })
	expect(started).toBe(true)
	expect(failure).toBeNil()
end

function ActionResourceTestUtils.registerActor(): (
	Actor,
	ActionTypes.ActionController,
	ResourceTypes.ResourceController,
	PropertyTypes.PropertyController,
	TagTypes.TagController
)
	local model: Model = Instance.new("Model")
	model.Parent = workspace
	table.insert(models, model)
	local actor: Actor?, reason: string? = ActorRuntime.RegisterActor(model)
	expect(reason).toBeNil()
	expect(actor).never.toBeNil()
	local registered: Actor = actor :: Actor
	table.insert(actors, registered)
	return registered,
		registered:GetController("ActionController") :: ActionTypes.ActionController,
		registered:GetController("ResourceController") :: ResourceTypes.ResourceController,
		registered:GetController("PropertyController") :: PropertyTypes.PropertyController,
		registered:GetController("TagController") :: TagTypes.TagController
end

-- Broad contract tests check rejection categories; the focused Resource planning
-- cases pin the public AC7 reason strings exactly.
function ActionResourceTestUtils.expectRejected(result: ActionTypes.ActionRequestResult): string
	expect(result.accepted).toBe(false)
	if result.accepted then
		error("Expected Action Resource rejection")
	end
	expect(type(result.reason)).toBe("string")
	expect(result.reason).never.toBe("")
	expect(result.reason).never.toBe("ActionLockConflict")
	for _, unrelatedReason: string in
		{
			"ActionFactoryFailed",
			"ActionFactoryYielded",
			"ActionFactoryInvalidResult",
			"ActionCanStartFailed",
			"ActionCanStartYielded",
			"ActionCanStartInvalidResult",
			"ActionCanStartRejected",
			"ActionInterruptDecisionFailed",
			"ActionInterruptDecisionYielded",
			"ActionInterruptDecisionInvalidResult",
		}
	do
		expect(result.reason).never.toBe(unrelatedReason)
	end
	return result.reason
end

return ActionResourceTestUtils
