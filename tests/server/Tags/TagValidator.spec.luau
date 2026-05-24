--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect

local RegistryTypes = require(KRF.server.Tags.types)
local TagValidator = require(KRF.server.Tags.TagValidator)

type TagDefinition = RegistryTypes.TagDefinition

local function createValidTagDefinition(): TagDefinition
	return {
		id = "Status.Rooted",
		duplicateBehavior = "Refresh",
		visibility = "ServerOnly",
	}
end

it("TagValidator.ValidateTagDefinition rejects missing and non-table definitions", function()
	local isMissingValid: boolean, missingReason: string? = TagValidator.ValidateTagDefinition(nil :: any, {})
	expect(isMissingValid).toBe(false)
	expect(missingReason).toBe("TagDefinitionMissing")

	local isNonTableValid: boolean, nonTableReason: string? =
		TagValidator.ValidateTagDefinition("not a table" :: any, {})
	expect(isNonTableValid).toBe(false)
	expect(nonTableReason).toBe("TagDefinitionMustBeTable")
end)

it("TagValidator.ValidateTagDefinition rejects non-string tag ids before registration lookup", function()
	local tagDefinition: TagDefinition = createValidTagDefinition();
	(tagDefinition :: any).id = 123

	local isValid: boolean, reason: string? = TagValidator.ValidateTagDefinition(tagDefinition, {})

	expect(isValid).toBe(false)
	expect(reason).toBe("TagIdMustBeString")
end)

it("TagValidator.ValidateTagDefinition requires duplicateBehavior and visibility to be strings", function()
	local missingDuplicateBehavior: TagDefinition = createValidTagDefinition();
	(missingDuplicateBehavior :: any).duplicateBehavior = nil

	local isMissingDuplicateBehaviorValid: boolean, missingDuplicateBehaviorReason: string? =
		TagValidator.ValidateTagDefinition(missingDuplicateBehavior, {})
	expect(isMissingDuplicateBehaviorValid).toBe(false)
	expect(missingDuplicateBehaviorReason).toBe("TagDuplicateBehaviorMissing")

	local nonStringDuplicateBehavior: TagDefinition = createValidTagDefinition();
	(nonStringDuplicateBehavior :: any).duplicateBehavior = 123

	local isNonStringDuplicateBehaviorValid: boolean, nonStringDuplicateBehaviorReason: string? =
		TagValidator.ValidateTagDefinition(nonStringDuplicateBehavior, {})
	expect(isNonStringDuplicateBehaviorValid).toBe(false)
	expect(nonStringDuplicateBehaviorReason).toBe("TagDuplicateBehaviorMustBeString")

	local missingVisibility: TagDefinition = createValidTagDefinition();
	(missingVisibility :: any).visibility = nil

	local isMissingVisibilityValid: boolean, missingVisibilityReason: string? =
		TagValidator.ValidateTagDefinition(missingVisibility, {})
	expect(isMissingVisibilityValid).toBe(false)
	expect(missingVisibilityReason).toBe("TagVisibilityMissing")

	local nonStringVisibility: TagDefinition = createValidTagDefinition();
	(nonStringVisibility :: any).visibility = 123

	local isNonStringVisibilityValid: boolean, nonStringVisibilityReason: string? =
		TagValidator.ValidateTagDefinition(nonStringVisibility, {})
	expect(isNonStringVisibilityValid).toBe(false)
	expect(nonStringVisibilityReason).toBe("TagVisibilityMustBeString")
end)

it("TagValidator.ValidateTagDefinition rejects non-function onTick handlers with a stable error", function()
	local tagDefinition: TagDefinition = createValidTagDefinition();
	(tagDefinition :: any).onTick = "tick"

	local isValid: boolean, reason: string? = TagValidator.ValidateTagDefinition(tagDefinition, {})

	expect(isValid).toBe(false)
	expect(reason).toBe("TagOnTickMustBeFunction")
end)
