--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect

local ActionTypes: any = require(KRF.server.Action.types)
local ActionValidator = require(KRF.server.Action.ActionValidator)

type ActionDefinition = ActionTypes.ActionDefinition

local preparedActionIds: { [string]: boolean } = {
	["Action.Dodge"] = true,
	["Action.Roll"] = true,
}
local preparedTagIds: { [string]: boolean } = {
	["Tag.Grounded"] = true,
	["Tag.Stunned"] = true,
}
local preparedResourceIds: { [string]: boolean } = {
	["Resource.Stamina"] = true,
}

local function createValidDefinition(): ActionDefinition
	return {
		id = "Action.Dodge",
		visibility = "ServerOnly",
	}
end

local function expectInvalid(definition: any, reason: string, actionIds: { [string]: boolean }?)
	local valid: boolean, actualReason: string? = ActionValidator.ValidateActionDefinition(
		definition,
		actionIds or preparedActionIds,
		preparedTagIds,
		preparedResourceIds
	)
	expect(valid).toBe(false)
	expect(actualReason).toBe(reason)
end

it("accepts a minimal Action definition and all optional Action metadata together", function()
	local definition: ActionDefinition = createValidDefinition()
	definition.autoGrant = true
	definition.visibility = "ClientVisible"
	definition.requiredTags = { "Tag.Grounded" }
	definition.blockedTags = { "Tag.Stunned" }
	definition.costs = { ["Resource.Stamina"] = 15 }
	definition.locks = { "Locomotion" }
	definition.interruptibleBy = { "Action.Roll" }
	definition.onCanStart = function(): (boolean, string?)
		return true, nil
	end
	definition.onStart = function(): () end
	definition.onUpdate = function(): () end
	definition.onEnd = function(): () end
	definition.onInterrupt = function(): () end
	definition.canBeInterruptedBy = function(): boolean
		return true
	end

	local valid: boolean, reason: string? =
		ActionValidator.ValidateActionDefinition(definition, preparedActionIds, preparedTagIds, preparedResourceIds)
	expect(valid).toBe(true)
	expect(reason).toBeNil()
end)

it("rejects malformed definitions and missing, non-string, empty, or duplicate Action ids", function()
	expectInvalid(nil, "ActionDefinitionMissing")
	expectInvalid("Action.Dodge", "ActionDefinitionMustBeTable")
	local missingId: any = createValidDefinition()
	missingId.id = nil
	expectInvalid(missingId, "ActionIdMissing")
	local nonStringId: any = createValidDefinition()
	nonStringId.id = 1
	expectInvalid(nonStringId, "ActionIdMustBeString")
	local emptyId: any = createValidDefinition()
	emptyId.id = ""
	expectInvalid(emptyId, "ActionIdCannotBeEmpty")
	local valid: boolean, reason: string? = ActionValidator.ValidateCatalog(
		{ createValidDefinition(), createValidDefinition() },
		preparedTagIds,
		preparedResourceIds
	)
	expect(valid).toBe(false)
	expect(reason).toBe("ActionIdAlreadyRegistered")
end)

it("rejects sparse or keyed catalogs and declaration lists instead of silently skipping entries", function()
	local malformedCatalogs: { any } = {
		false,
		{ named = createValidDefinition() },
		{ [2] = createValidDefinition() },
	}
	for index: number, catalog: any in malformedCatalogs do
		local valid: boolean, reason: string? =
			ActionValidator.ValidateCatalog(catalog, preparedTagIds, preparedResourceIds)
		expect(valid).toBe(false)
		expect(reason).toBe(if index == 1 then "ActionDefinitionsMustBeTable" else "ActionDefinitionsMustBeArray")
	end
	local invalidIdentity: boolean, identityReason: string? =
		ActionValidator.ValidateCatalog({ {} } :: any, preparedTagIds, preparedResourceIds)
	expect(invalidIdentity).toBe(false)
	expect(identityReason).toBe("ActionIdMissing")
	local malformedDeclarations: { any } = {
		{ named = "Tag.Grounded" },
		{ [2] = "Tag.Grounded" },
		{ [0] = "Tag.Grounded" },
		{ [1.5] = "Tag.Grounded" },
	}
	for _, field: string in { "requiredTags", "blockedTags", "locks", "interruptibleBy" } do
		for _, declaration: any in malformedDeclarations do
			local definition: any = createValidDefinition()
			definition[field] = declaration
			expectInvalid(definition, `Action{string.upper(string.sub(field, 1, 1))}{string.sub(field, 2)}MustBeArray`)
		end
	end
end)

it("reports unsupported fields and invalid cost references deterministically", function()
	local definition: any = createValidDefinition()
	definition.priority = 1
	definition.category = "Movement"
	expectInvalid(definition, "ActionFieldUnsupported:category")
	definition = createValidDefinition()
	definition[1] = true
	expectInvalid(definition, "ActionFieldMustBeString")
	definition = createValidDefinition()
	definition.costs = { ["Resource.Zebra"] = 1, ["Resource.Alpha"] = 1 }
	expectInvalid(definition, "ActionCostResourceUnknown:Resource.Alpha")
	for _, amount: number in { -math.huge, 0 / 0 } do
		definition.costs = { ["Resource.Stamina"] = amount }
		expectInvalid(definition, "ActionCostMustBeFiniteNumber")
	end
end)

it("requires ServerOnly or ClientVisible visibility and a boolean autoGrant when supplied", function()
	local missingVisibility: any = createValidDefinition()
	missingVisibility.visibility = nil
	expectInvalid(missingVisibility, "ActionVisibilityMissing")
	local nonStringVisibility: any = createValidDefinition()
	nonStringVisibility.visibility = 1
	expectInvalid(nonStringVisibility, "ActionVisibilityMustBeString")
	local invalidVisibility: any = createValidDefinition()
	invalidVisibility.visibility = "Everyone"
	expectInvalid(invalidVisibility, "ActionVisibilityInvalid")
	local invalidAutoGrant: any = createValidDefinition()
	invalidAutoGrant.autoGrant = "yes"
	expectInvalid(invalidAutoGrant, "ActionAutoGrantMustBeBoolean")
end)

it("accepts every lifecycle and preemption hook only when it is a function", function()
	local hookFields: { string } = { "onCanStart", "onStart", "onUpdate", "onEnd", "onInterrupt", "canBeInterruptedBy" }
	for _, hookField: string in hookFields do
		local validDefinition: any = createValidDefinition()
		validDefinition[hookField] = function() end
		local valid: boolean, reason: string? = ActionValidator.ValidateActionDefinition(
			validDefinition,
			preparedActionIds,
			preparedTagIds,
			preparedResourceIds
		)
		expect(valid).toBe(true)
		expect(reason).toBeNil()

		local invalidDefinition: any = createValidDefinition()
		invalidDefinition[hookField] = "not a function"
		expectInvalid(
			invalidDefinition,
			`Action{string.upper(string.sub(hookField, 1, 1))}{string.sub(hookField, 2)}MustBeFunction`
		)
	end
end)

it("validates required and blocked Tag lists as distinct, unique prepared Tag references", function()
	local nonTableRequired: any = createValidDefinition()
	nonTableRequired.requiredTags = "Tag.Grounded"
	expectInvalid(nonTableRequired, "ActionRequiredTagsMustBeTable")
	local emptyRequired: any = createValidDefinition()
	emptyRequired.requiredTags = { "" }
	expectInvalid(emptyRequired, "ActionRequiredTagIdCannotBeEmpty")
	local nonStringRequired: any = createValidDefinition()
	nonStringRequired.requiredTags = { 1 }
	expectInvalid(nonStringRequired, "ActionRequiredTagIdMustBeString")
	local duplicateRequired: any = createValidDefinition()
	duplicateRequired.requiredTags = { "Tag.Grounded", "Tag.Grounded" }
	expectInvalid(duplicateRequired, "ActionRequiredTagIdDuplicate")
	local unknownRequired: any = createValidDefinition()
	unknownRequired.requiredTags = { "Tag.Unknown" }
	expectInvalid(unknownRequired, "ActionRequiredTagUnknown:Tag.Unknown")
	local nonTableBlocked: any = createValidDefinition()
	nonTableBlocked.blockedTags = "Tag.Stunned"
	expectInvalid(nonTableBlocked, "ActionBlockedTagsMustBeTable")
	local emptyBlocked: any = createValidDefinition()
	emptyBlocked.blockedTags = { "" }
	expectInvalid(emptyBlocked, "ActionBlockedTagIdCannotBeEmpty")
	local nonStringBlocked: any = createValidDefinition()
	nonStringBlocked.blockedTags = { 1 }
	expectInvalid(nonStringBlocked, "ActionBlockedTagIdMustBeString")
	local duplicateBlocked: any = createValidDefinition()
	duplicateBlocked.blockedTags = { "Tag.Stunned", "Tag.Stunned" }
	expectInvalid(duplicateBlocked, "ActionBlockedTagIdDuplicate")
	local unknownBlocked: any = createValidDefinition()
	unknownBlocked.blockedTags = { "Tag.Unknown" }
	expectInvalid(unknownBlocked, "ActionBlockedTagUnknown:Tag.Unknown")
	local overlappingTags: any = createValidDefinition()
	overlappingTags.requiredTags = { "Tag.Grounded" }
	overlappingTags.blockedTags = { "Tag.Grounded" }
	expectInvalid(overlappingTags, "ActionRequiredAndBlockedTagsOverlap:Tag.Grounded")
end)

it("validates Resource costs as a finite positive map of prepared Resource ids", function()
	local nonTableCosts: any = createValidDefinition()
	nonTableCosts.costs = "Resource.Stamina"
	expectInvalid(nonTableCosts, "ActionCostsMustBeTable")
	local emptyResourceId: any = createValidDefinition()
	emptyResourceId.costs = { [""] = 1 }
	expectInvalid(emptyResourceId, "ActionCostResourceIdCannotBeEmpty")
	local nonStringResourceId: any = createValidDefinition()
	nonStringResourceId.costs = { [1] = 1 }
	expectInvalid(nonStringResourceId, "ActionCostResourceIdMustBeString")
	local unknownResourceId: any = createValidDefinition()
	unknownResourceId.costs = { ["Resource.Unknown"] = 1 }
	expectInvalid(unknownResourceId, "ActionCostResourceUnknown:Resource.Unknown")
	local nonNumberCost: any = createValidDefinition()
	nonNumberCost.costs = { ["Resource.Stamina"] = "10" }
	expectInvalid(nonNumberCost, "ActionCostMustBeNumber")
	local nonFiniteCost: any = createValidDefinition()
	nonFiniteCost.costs = { ["Resource.Stamina"] = math.huge }
	expectInvalid(nonFiniteCost, "ActionCostMustBeFiniteNumber")
	local zeroCost: any = createValidDefinition()
	zeroCost.costs = { ["Resource.Stamina"] = 0 }
	expectInvalid(zeroCost, "ActionCostMustBePositive")
	local negativeCost: any = createValidDefinition()
	negativeCost.costs = { ["Resource.Stamina"] = -1 }
	expectInvalid(negativeCost, "ActionCostMustBePositive")
end)

it("validates unique non-empty string lock and interruptible Action ids against the complete catalog", function()
	local nonTableLocks: any = createValidDefinition()
	nonTableLocks.locks = "Locomotion"
	expectInvalid(nonTableLocks, "ActionLocksMustBeTable")
	local nonStringLock: any = createValidDefinition()
	nonStringLock.locks = { 1 }
	expectInvalid(nonStringLock, "ActionLockIdMustBeString")
	local emptyLock: any = createValidDefinition()
	emptyLock.locks = { "" }
	expectInvalid(emptyLock, "ActionLockIdCannotBeEmpty")
	local duplicateLocks: any = createValidDefinition()
	duplicateLocks.locks = { "Locomotion", "Locomotion" }
	expectInvalid(duplicateLocks, "ActionLockIdDuplicate")
	local nonTableInterruptibleBy: any = createValidDefinition()
	nonTableInterruptibleBy.interruptibleBy = "Action.Roll"
	expectInvalid(nonTableInterruptibleBy, "ActionInterruptibleByMustBeTable")
	local emptyInterruptibleBy: any = createValidDefinition()
	emptyInterruptibleBy.interruptibleBy = { "" }
	expectInvalid(emptyInterruptibleBy, "ActionInterruptibleByIdCannotBeEmpty")
	local nonStringInterruptibleBy: any = createValidDefinition()
	nonStringInterruptibleBy.interruptibleBy = { 1 }
	expectInvalid(nonStringInterruptibleBy, "ActionInterruptibleByIdMustBeString")
	local duplicateInterruptibleBy: any = createValidDefinition()
	duplicateInterruptibleBy.interruptibleBy = { "Action.Roll", "Action.Roll" }
	expectInvalid(duplicateInterruptibleBy, "ActionInterruptibleByIdDuplicate")
	local unknownInterruptibleBy: any = createValidDefinition()
	unknownInterruptibleBy.interruptibleBy = { "Action.Unknown" }
	expectInvalid(unknownInterruptibleBy, "ActionInterruptibleByUnknown:Action.Unknown")
	local forwardReference: any = createValidDefinition()
	forwardReference.id = "Action.First"
	forwardReference.interruptibleBy = { "Action.Second" }
	local valid: boolean, reason: string? = ActionValidator.ValidateActionDefinition(
		forwardReference,
		{ ["Action.First"] = true, ["Action.Second"] = true },
		preparedTagIds,
		preparedResourceIds
	)
	expect(valid).toBe(true)
	expect(reason).toBeNil()
end)

it(
	"rejects fields outside the AC1 schema so excluded taxonomy and runtime metadata cannot become implicit API",
	function()
		for _, excludedField: string in
			{ "kind", "cooldown", "phase", "combo", "buffer", "priority", "category", "duration" }
		do
			local definition: any = createValidDefinition()
			definition[excludedField] = true
			expectInvalid(definition, `ActionFieldUnsupported:{excludedField}`)
		end
	end
)
