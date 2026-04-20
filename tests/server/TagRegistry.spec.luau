local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect

local RegistryTypes: unknown = require(KRF.server.Tags.types)

type TagRegistry = RegistryTypes.TagRegistry

local TagRegistry: TagRegistry = require(KRF.server.Tags.TagRegistry)

local TagTestUtils: Folder = script.Parent.Utils.Tags
local MinimalValidCataloge: unknown = require(TagTestUtils.MinimalTagCatalog)
local MixedTagCataloge: unknown = require(TagTestUtils.MixedTagCatalog)
local MissingTagIdCataloge: unknown = require(TagTestUtils.MissingTagIdCatalog)
local EmptyTagIdCataloge: unknown = require(TagTestUtils.EmptyTagIdCatalog)
local DuplicateTagIdCataloge: unknown = require(TagTestUtils.DuplicateTagIdCatalog)
local InvalidDuplicateBehaviorCataloge: unknown = require(TagTestUtils.InvalidDuplicateBehaviorCatalog)
local InvalidVisibilityCataloge: unknown = require(TagTestUtils.InvalidVisibilityCatalog)
local NonNumericDefaultDurationCataloge: unknown = require(TagTestUtils.NonNumericDefaultDurationCatalog)
local NonPositiveDefaultDurationCataloge: unknown = require(TagTestUtils.NonPositiveDefaultDurationCatalog)
local NonNumericTickIntervalCataloge: unknown = require(TagTestUtils.NonNumericTickIntervalCatalog)
local NonPositiveTickIntervalCataloge: unknown = require(TagTestUtils.NonPositiveTickIntervalCatalog)
local NonNumericMaxStacksCataloge: unknown = require(TagTestUtils.NonNumericMaxStacksCatalog)
local NonPositiveMaxStacksCataloge: unknown = require(TagTestUtils.NonPositiveMaxStacksCatalog)
local NonIntegerMaxStacksCataloge: unknown = require(TagTestUtils.NonIntegerMaxStacksCatalog)
local MaxStacksWithoutStackDuplicateBehaviorCataloge: unknown =
	require(TagTestUtils.MaxStacksWithoutStackDuplicateBehaviorCatalog)
local ValidPropertyModifierCataloge: unknown = require(TagTestUtils.ValidPropertyModifierCatalog)
local MixedPropertyModifierModeCataloge: unknown = require(TagTestUtils.MixedPropertyModifierModeCatalog)
local MixedSetMultiplyPropertyModifierCataloge: unknown = require(TagTestUtils.MixedSetMultiplyPropertyModifierCatalog)
local MixedSetMinPropertyModifierCataloge: unknown = require(TagTestUtils.MixedSetMinPropertyModifierCatalog)
local MixedSetMaxPropertyModifierCataloge: unknown = require(TagTestUtils.MixedSetMaxPropertyModifierCatalog)
local NonNumericSetPropertyModifierCataloge: unknown = require(TagTestUtils.NonNumericSetPropertyModifierCatalog)
local NonNumericAddPropertyModifierCataloge: unknown = require(TagTestUtils.NonNumericAddPropertyModifierCatalog)
local NonNumericMultiplyPropertyModifierCataloge: unknown =
	require(TagTestUtils.NonNumericMultiplyPropertyModifierCatalog)
local NonNumericMinPropertyModifierCataloge: unknown = require(TagTestUtils.NonNumericMinPropertyModifierCatalog)
local NonNumericMaxPropertyModifierCataloge: unknown = require(TagTestUtils.NonNumericMaxPropertyModifierCatalog)

it("TagRegistry.Load accepts valid catalogs across minimal and mixed metadata cases", function()
	TagRegistry._resetForTests()

	local minimalLoaded: boolean, minimalReason: string? = TagRegistry.Load(MinimalValidCataloge)
	expect(minimalLoaded).toBe(true)
	expect(minimalReason).toBeNil()

	TagRegistry._resetForTests()

	local mixedLoaded: boolean, mixedReason: string? = TagRegistry.Load(MixedTagCataloge)
	expect(mixedLoaded).toBe(true)
	expect(mixedReason).toBeNil()
end)

it("TagRegistry.Load rejects tag definitions with missing, empty, or duplicate ids", function()
	TagRegistry._resetForTests()

	local missingIdLoaded: boolean, missingIdReason: string? = TagRegistry.Load(MissingTagIdCataloge)
	expect(missingIdLoaded).toBe(false)
	expect(missingIdReason).toBe("TagIdMissing")

	local emptyIdLoaded: boolean, emptyIdReason: string? = TagRegistry.Load(EmptyTagIdCataloge)
	expect(emptyIdLoaded).toBe(false)
	expect(emptyIdReason).toBe("TagIdCannotBeEmpty")

	local duplicateIdLoaded: boolean, duplicateIdReason: string? = TagRegistry.Load(DuplicateTagIdCataloge)
	expect(duplicateIdLoaded).toBe(false)
	expect(duplicateIdReason).toBe("TagIdAlreadyRegistered")
end)

it("TagRegistry.Load rejects invalid duplicateBehavior and visibility values", function()
	TagRegistry._resetForTests()

	local invalidDuplicateBehaviorLoaded: boolean, invalidDuplicateBehaviorReason: string? =
		TagRegistry.Load(InvalidDuplicateBehaviorCataloge)
	expect(invalidDuplicateBehaviorLoaded).toBe(false)
	expect(invalidDuplicateBehaviorReason).toBe("TagDuplicateBehaviorInvalid")

	local invalidVisibilityLoaded: boolean, invalidVisibilityReason: string? =
		TagRegistry.Load(InvalidVisibilityCataloge)
	expect(invalidVisibilityLoaded).toBe(false)
	expect(invalidVisibilityReason).toBe("TagVisibilityInvalid")
end)

it("TagRegistry.Load rejects invalid defaultDuration and tickInterval values", function()
	TagRegistry._resetForTests()

	local nonNumericDefaultDurationLoaded: boolean, nonNumericDefaultDurationReason: string? =
		TagRegistry.Load(NonNumericDefaultDurationCataloge)
	expect(nonNumericDefaultDurationLoaded).toBe(false)
	expect(nonNumericDefaultDurationReason).toBe("TagDefaultDurationMustBeNumber")

	local nonPositiveDefaultDurationLoaded: boolean, nonPositiveDefaultDurationReason: string? =
		TagRegistry.Load(NonPositiveDefaultDurationCataloge)
	expect(nonPositiveDefaultDurationLoaded).toBe(false)
	expect(nonPositiveDefaultDurationReason).toBe("TagDefaultDurationMustBePositive")

	local nonNumericTickIntervalLoaded: boolean, nonNumericTickIntervalReason: string? =
		TagRegistry.Load(NonNumericTickIntervalCataloge)
	expect(nonNumericTickIntervalLoaded).toBe(false)
	expect(nonNumericTickIntervalReason).toBe("TagTickIntervalMustBeNumber")

	local nonPositiveTickIntervalLoaded: boolean, nonPositiveTickIntervalReason: string? =
		TagRegistry.Load(NonPositiveTickIntervalCataloge)
	expect(nonPositiveTickIntervalLoaded).toBe(false)
	expect(nonPositiveTickIntervalReason).toBe("TagTickIntervalMustBePositive")
end)

it("TagRegistry.Load enforces maxStacks validation rules", function()
	TagRegistry._resetForTests()

	local nonNumericMaxStacksLoaded: boolean, nonNumericMaxStacksReason: string? =
		TagRegistry.Load(NonNumericMaxStacksCataloge)
	expect(nonNumericMaxStacksLoaded).toBe(false)
	expect(nonNumericMaxStacksReason).toBe("TagMaxStacksMustBeNumber")

	local nonPositiveMaxStacksLoaded: boolean, nonPositiveMaxStacksReason: string? =
		TagRegistry.Load(NonPositiveMaxStacksCataloge)
	expect(nonPositiveMaxStacksLoaded).toBe(false)
	expect(nonPositiveMaxStacksReason).toBe("TagMaxStacksMustBePositive")

	local nonIntegerMaxStacksLoaded: boolean, nonIntegerMaxStacksReason: string? =
		TagRegistry.Load(NonIntegerMaxStacksCataloge)
	expect(nonIntegerMaxStacksLoaded).toBe(false)
	expect(nonIntegerMaxStacksReason).toBe("TagMaxStacksMustBeInteger")

	local maxStacksWithoutStackDuplicateBehaviorLoaded: boolean, maxStacksWithoutStackDuplicateBehaviorReason: string? =
		TagRegistry.Load(MaxStacksWithoutStackDuplicateBehaviorCataloge)
	expect(maxStacksWithoutStackDuplicateBehaviorLoaded).toBe(false)
	expect(maxStacksWithoutStackDuplicateBehaviorReason).toBe("TagMaxStacksRequiresStackDuplicateBehavior")
end)

it("TagRegistry.Load accepts valid property modifier shapes in override and normal modifier modes", function()
	TagRegistry._resetForTests()

	local validPropertyModifierLoaded: boolean, validPropertyModifierReason: string? =
		TagRegistry.Load(ValidPropertyModifierCataloge)
	expect(validPropertyModifierLoaded).toBe(true)
	expect(validPropertyModifierReason).toBeNil()
end)

it("TagRegistry.Load rejects property entries that mix override and normal modifier fields", function()
	TagRegistry._resetForTests()

	local mixedPropertyModifierModeLoaded: boolean, mixedPropertyModifierModeReason: string? =
		TagRegistry.Load(MixedPropertyModifierModeCataloge)
	expect(mixedPropertyModifierModeLoaded).toBe(false)
	expect(mixedPropertyModifierModeReason).toBe("TagPropertyModifierSetCannotBeCombined")

	local mixedSetMultiplyPropertyModifierLoaded: boolean, mixedSetMultiplyPropertyModifierReason: string? =
		TagRegistry.Load(MixedSetMultiplyPropertyModifierCataloge)
	expect(mixedSetMultiplyPropertyModifierLoaded).toBe(false)
	expect(mixedSetMultiplyPropertyModifierReason).toBe("TagPropertyModifierSetCannotBeCombined")

	local mixedSetMinPropertyModifierLoaded: boolean, mixedSetMinPropertyModifierReason: string? =
		TagRegistry.Load(MixedSetMinPropertyModifierCataloge)
	expect(mixedSetMinPropertyModifierLoaded).toBe(false)
	expect(mixedSetMinPropertyModifierReason).toBe("TagPropertyModifierSetCannotBeCombined")

	local mixedSetMaxPropertyModifierLoaded: boolean, mixedSetMaxPropertyModifierReason: string? =
		TagRegistry.Load(MixedSetMaxPropertyModifierCataloge)
	expect(mixedSetMaxPropertyModifierLoaded).toBe(false)
	expect(mixedSetMaxPropertyModifierReason).toBe("TagPropertyModifierSetCannotBeCombined")
end)

it("TagRegistry.Load rejects non-numeric property modifier values", function()
	TagRegistry._resetForTests()

	local nonNumericSetPropertyModifierLoaded: boolean, nonNumericSetPropertyModifierReason: string? =
		TagRegistry.Load(NonNumericSetPropertyModifierCataloge)
	expect(nonNumericSetPropertyModifierLoaded).toBe(false)
	expect(nonNumericSetPropertyModifierReason).toBe("TagPropertyModifierValueMustBeNumber")

	local nonNumericAddPropertyModifierLoaded: boolean, nonNumericAddPropertyModifierReason: string? =
		TagRegistry.Load(NonNumericAddPropertyModifierCataloge)
	expect(nonNumericAddPropertyModifierLoaded).toBe(false)
	expect(nonNumericAddPropertyModifierReason).toBe("TagPropertyModifierValueMustBeNumber")

	local nonNumericMultiplyPropertyModifierLoaded: boolean, nonNumericMultiplyPropertyModifierReason: string? =
		TagRegistry.Load(NonNumericMultiplyPropertyModifierCataloge)
	expect(nonNumericMultiplyPropertyModifierLoaded).toBe(false)
	expect(nonNumericMultiplyPropertyModifierReason).toBe("TagPropertyModifierValueMustBeNumber")

	local nonNumericMinPropertyModifierLoaded: boolean, nonNumericMinPropertyModifierReason: string? =
		TagRegistry.Load(NonNumericMinPropertyModifierCataloge)
	expect(nonNumericMinPropertyModifierLoaded).toBe(false)
	expect(nonNumericMinPropertyModifierReason).toBe("TagPropertyModifierValueMustBeNumber")

	local nonNumericMaxPropertyModifierLoaded: boolean, nonNumericMaxPropertyModifierReason: string? =
		TagRegistry.Load(NonNumericMaxPropertyModifierCataloge)
	expect(nonNumericMaxPropertyModifierLoaded).toBe(false)
	expect(nonNumericMaxPropertyModifierReason).toBe("TagPropertyModifierValueMustBeNumber")
end)

it("TagRegistry.Load rejects unknown or malformed property modifier metadata", function() end)

it("TagRegistry.Load failure does not partially commit catalog state", function() end)

it("TagRegistry.IsLoaded reflects registry state before and after successful load", function() end)

it("TagRegistry.Get returns the registered definition for known ids and nil for unknown ids", function() end)

it("TagRegistry.GetAll returns every registered definition in deterministic order", function() end)
it("TagRegistry rejects a second load after a successful startup load", function() end)
it("TagRegistry read surfaces remain stable after load and do not expose mutable registry state", function() end)
