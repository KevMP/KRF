--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect

local ActorTypes = require(KRF.server.Actor.types)
local PropertyTypes = require(KRF.server.Property.types)
local ResourceTypes = require(KRF.server.Resource.types)

type Actor = ActorTypes.Actor
type PropertyController = PropertyTypes.PropertyController
type ResourceDefinition = ResourceTypes.ResourceDefinition

local ActorEntity = require(KRF.server.Actor.ActorEntity)
local PropertyControllerModule = require(KRF.server.Property.PropertyController)
local ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)

local ResourceControllerTestUtils = {}

function ResourceControllerTestUtils.createActorWithPropertyController(): (Actor, PropertyController)
	local actor: Actor = ActorEntity.new()
	local propertyController: PropertyController = PropertyControllerModule.new(actor)
	local setPropertyControllerOk: boolean = actor:SetController("PropertyController", propertyController)
	expect(setPropertyControllerOk).toBe(true)

	return actor, propertyController
end

function ResourceControllerTestUtils.createActorWithCustomPropertyController(propertyController: any): Actor
	local actor: Actor = ActorEntity.new()
	local setPropertyControllerOk: boolean = actor:SetController("PropertyController", propertyController)
	expect(setPropertyControllerOk).toBe(true)

	return actor
end

function ResourceControllerTestUtils.resetAndLoadDefinitions(definitions: { ResourceDefinition }): ()
	ResourceRegistry._resetForTests()

	local loaded: boolean, loadReason: string? = ResourceRegistry.Load(definitions)
	expect(loaded).toBe(true)
	expect(loadReason).toBeNil()
end

return ResourceControllerTestUtils
