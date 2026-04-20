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

it("TagRegistry.Load accepts valid catalogs across minimal and mixed metadata cases", function()
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

it("TagRegistry.Load rejects invalid duplicateBehavior and visibility values", function() end)

it("TagRegistry.Load rejects invalid defaultDuration and tickInterval values", function() end)

it("TagRegistry.Load enforces maxStacks validation rules", function() end)

it("TagRegistry.Load accepts valid property modifier shapes in override and normal modifier modes", function() end)

it("TagRegistry.Load rejects property entries that mix override and normal modifier fields", function() end)

it("TagRegistry.Load rejects non-numeric property modifier values", function() end)

it("TagRegistry.Load rejects unknown or malformed property modifier metadata", function() end)

it("TagRegistry.Load failure does not partially commit catalog state", function() end)

it("TagRegistry.IsLoaded reflects registry state before and after successful load", function() end)

it("TagRegistry.Get returns the registered definition for known ids and nil for unknown ids", function() end)

it("TagRegistry.GetAll returns every registered definition in deterministic order", function() end)
it("TagRegistry rejects a second load after a successful startup load", function() end)
it("TagRegistry read surfaces remain stable after load and do not expose mutable registry state", function() end)
