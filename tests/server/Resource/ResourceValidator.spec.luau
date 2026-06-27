--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect

local ResourceTypes: unknown = require(KRF.server.Resource.types)
local ResourceValidator = require(KRF.server.Resource.utils.ResourceValidator)

type ResourceDefinition = ResourceTypes.ResourceDefinition

local function createValidResourceDefinition(): ResourceDefinition
	return {
		id = "Resource.Stamina",
		max = {
			value = 100,
		},
		visibility = "ServerOnly",
	}
end

it("ResourceValidator.ValidateResourceDefinition rejects missing and non-table definitions", function()
	local isMissingValid: boolean, missingReason: string? = ResourceValidator.ValidateResourceDefinition(nil :: any, {})
	expect(isMissingValid).toBe(false)
	expect(missingReason).toBe("ResourceDefinitionMissing")

	local isNonTableValid: boolean, nonTableReason: string? =
		ResourceValidator.ValidateResourceDefinition("not a table" :: any, {})
	expect(isNonTableValid).toBe(false)
	expect(nonTableReason).toBe("ResourceDefinitionMustBeTable")
end)

it(
	"ResourceValidator.ValidateResourceDefinition rejects missing, empty, non-string, and duplicate resource ids",
	function()
		local missingIdDefinition: ResourceDefinition = createValidResourceDefinition();
		(missingIdDefinition :: any).id = nil

		local isMissingIdValid: boolean, missingIdReason: string? =
			ResourceValidator.ValidateResourceDefinition(missingIdDefinition, {})
		expect(isMissingIdValid).toBe(false)
		expect(missingIdReason).toBe("ResourceIdMissing")

		local emptyIdDefinition: ResourceDefinition = createValidResourceDefinition();
		(emptyIdDefinition :: any).id = ""

		local isEmptyIdValid: boolean, emptyIdReason: string? =
			ResourceValidator.ValidateResourceDefinition(emptyIdDefinition, {})
		expect(isEmptyIdValid).toBe(false)
		expect(emptyIdReason).toBe("ResourceIdCannotBeEmpty")

		local nonStringIdDefinition: ResourceDefinition = createValidResourceDefinition();
		(nonStringIdDefinition :: any).id = 123

		local isNonStringIdValid: boolean, nonStringIdReason: string? =
			ResourceValidator.ValidateResourceDefinition(nonStringIdDefinition, {
				["Resource.Stamina"] = createValidResourceDefinition(),
			})
		expect(isNonStringIdValid).toBe(false)
		expect(nonStringIdReason).toBe("ResourceIdMustBeString")

		local duplicateIdDefinition: ResourceDefinition = createValidResourceDefinition()
		local isDuplicateIdValid: boolean, duplicateIdReason: string? =
			ResourceValidator.ValidateResourceDefinition(duplicateIdDefinition, {
				["Resource.Stamina"] = createValidResourceDefinition(),
			})
		expect(isDuplicateIdValid).toBe(false)
		expect(duplicateIdReason).toBe("ResourceIdAlreadyRegistered")
	end
)

it("ResourceValidator.ValidateResourceDefinition requires valid visibility and scalar metadata types", function()
	local missingVisibilityDefinition: ResourceDefinition = createValidResourceDefinition();
	(missingVisibilityDefinition :: any).visibility = nil

	local isMissingVisibilityValid: boolean, missingVisibilityReason: string? =
		ResourceValidator.ValidateResourceDefinition(missingVisibilityDefinition, {})
	expect(isMissingVisibilityValid).toBe(false)
	expect(missingVisibilityReason).toBe("ResourceVisibilityMissing")

	local nonStringVisibilityDefinition: ResourceDefinition = createValidResourceDefinition();
	(nonStringVisibilityDefinition :: any).visibility = 123

	local isNonStringVisibilityValid: boolean, nonStringVisibilityReason: string? =
		ResourceValidator.ValidateResourceDefinition(nonStringVisibilityDefinition, {})
	expect(isNonStringVisibilityValid).toBe(false)
	expect(nonStringVisibilityReason).toBe("ResourceVisibilityMustBeString")

	local invalidVisibilityDefinition: ResourceDefinition = createValidResourceDefinition();
	(invalidVisibilityDefinition :: any).visibility = "Everyone"

	local isInvalidVisibilityValid: boolean, invalidVisibilityReason: string? =
		ResourceValidator.ValidateResourceDefinition(invalidVisibilityDefinition, {})
	expect(isInvalidVisibilityValid).toBe(false)
	expect(invalidVisibilityReason).toBe("ResourceVisibilityInvalid")

	local invalidInitialValueDefinition: ResourceDefinition = createValidResourceDefinition();
	(invalidInitialValueDefinition :: any).initialValue = "full"

	local isInvalidInitialValueValid: boolean, invalidInitialValueReason: string? =
		ResourceValidator.ValidateResourceDefinition(invalidInitialValueDefinition, {})
	expect(isInvalidInitialValueValid).toBe(false)
	expect(invalidInitialValueReason).toBe("ResourceInitialValueMustBeNumber")

	local invalidAutoAssignDefinition: ResourceDefinition = createValidResourceDefinition();
	(invalidAutoAssignDefinition :: any).autoAssign = "yes"

	local isInvalidAutoAssignValid: boolean, invalidAutoAssignReason: string? =
		ResourceValidator.ValidateResourceDefinition(invalidAutoAssignDefinition, {})
	expect(isInvalidAutoAssignValid).toBe(false)
	expect(invalidAutoAssignReason).toBe("ResourceAutoAssignMustBeBoolean")
end)

it("ResourceValidator.ValidateResourceDefinition rejects malformed max and min numeric sources", function()
	local missingMaxDefinition: ResourceDefinition = createValidResourceDefinition();
	(missingMaxDefinition :: any).max = nil

	local isMissingMaxValid: boolean, missingMaxReason: string? =
		ResourceValidator.ValidateResourceDefinition(missingMaxDefinition, {})
	expect(isMissingMaxValid).toBe(false)
	expect(missingMaxReason).toBe("ResourceMaxMissing")

	local nonTableMaxSourceDefinition: ResourceDefinition = createValidResourceDefinition();
	(nonTableMaxSourceDefinition :: any).max = 100

	local isNonTableMaxSourceValid: boolean, nonTableMaxSourceReason: string? =
		ResourceValidator.ValidateResourceDefinition(nonTableMaxSourceDefinition, {})
	expect(isNonTableMaxSourceValid).toBe(false)
	expect(nonTableMaxSourceReason).toBe("ResourceMaxMustBeTable")

	local mixedMaxSourceDefinition: ResourceDefinition = createValidResourceDefinition();
	(mixedMaxSourceDefinition :: any).max = {
		value = 100,
		propertyName = "MaxStamina",
		defaultBaseValue = 100,
	}

	local isMixedMaxSourceValid: boolean, mixedMaxSourceReason: string? =
		ResourceValidator.ValidateResourceDefinition(mixedMaxSourceDefinition, {})
	expect(isMixedMaxSourceValid).toBe(false)
	expect(mixedMaxSourceReason).toBe("ResourceMaxCannotUseValueAndPropertyNameTogether")

	local emptyMaxSourceDefinition: ResourceDefinition = createValidResourceDefinition();
	(emptyMaxSourceDefinition :: any).max = {}

	local isEmptyMaxSourceValid: boolean, emptyMaxSourceReason: string? =
		ResourceValidator.ValidateResourceDefinition(emptyMaxSourceDefinition, {})
	expect(isEmptyMaxSourceValid).toBe(false)
	expect(emptyMaxSourceReason).toBe("ResourceMaxMustProvideValueOrPropertyName")

	local nonNumericStaticMaxSourceDefinition: ResourceDefinition = createValidResourceDefinition();
	(nonNumericStaticMaxSourceDefinition :: any).max = {
		value = "100",
	}

	local isNonNumericStaticMaxSourceValid: boolean, nonNumericStaticMaxSourceReason: string? =
		ResourceValidator.ValidateResourceDefinition(nonNumericStaticMaxSourceDefinition, {})
	expect(isNonNumericStaticMaxSourceValid).toBe(false)
	expect(nonNumericStaticMaxSourceReason).toBe("ResourceMaxValueMustBeNumber")

	local invalidStaticMaxSourceDefinition: ResourceDefinition = createValidResourceDefinition();
	(invalidStaticMaxSourceDefinition :: any).max = {
		value = 100,
		defaultBaseValue = 100,
	}

	local isInvalidStaticMaxSourceValid: boolean, invalidStaticMaxSourceReason: string? =
		ResourceValidator.ValidateResourceDefinition(invalidStaticMaxSourceDefinition, {})
	expect(isInvalidStaticMaxSourceValid).toBe(false)
	expect(invalidStaticMaxSourceReason).toBe("ResourceMaxDefaultBaseValueRequiresPropertyName")

	local nonStringPropertyBackedMaxDefinition: ResourceDefinition = createValidResourceDefinition();
	(nonStringPropertyBackedMaxDefinition :: any).max = {
		propertyName = 123,
		defaultBaseValue = 100,
	}

	local isNonStringPropertyBackedMaxValid: boolean, nonStringPropertyBackedMaxReason: string? =
		ResourceValidator.ValidateResourceDefinition(nonStringPropertyBackedMaxDefinition, {})
	expect(isNonStringPropertyBackedMaxValid).toBe(false)
	expect(nonStringPropertyBackedMaxReason).toBe("ResourceMaxPropertyNameMustBeString")

	local invalidPropertyBackedMinDefinition: ResourceDefinition = createValidResourceDefinition();
	(invalidPropertyBackedMinDefinition :: any).min = {
		propertyName = "",
		defaultBaseValue = 0,
	}

	local isInvalidPropertyBackedMinValid: boolean, invalidPropertyBackedMinReason: string? =
		ResourceValidator.ValidateResourceDefinition(invalidPropertyBackedMinDefinition, {})
	expect(isInvalidPropertyBackedMinValid).toBe(false)
	expect(invalidPropertyBackedMinReason).toBe("ResourceMinPropertyNameCannotBeEmpty")
end)

it(
	"ResourceValidator.ValidateResourceDefinition rejects property-backed numeric sources without usable defaults",
	function()
		local missingDefaultBaseValueDefinition: ResourceDefinition = createValidResourceDefinition();
		(missingDefaultBaseValueDefinition :: any).max = {
			propertyName = "MaxStamina",
		}

		local isMissingDefaultBaseValueValid: boolean, missingDefaultBaseValueReason: string? =
			ResourceValidator.ValidateResourceDefinition(missingDefaultBaseValueDefinition, {})
		expect(isMissingDefaultBaseValueValid).toBe(false)
		expect(missingDefaultBaseValueReason).toBe("ResourceMaxDefaultBaseValueMissing")

		local nonNumericDefaultBaseValueDefinition: ResourceDefinition = createValidResourceDefinition();
		(nonNumericDefaultBaseValueDefinition :: any).max = {
			propertyName = "MaxStamina",
			defaultBaseValue = "100",
		}

		local isNonNumericDefaultBaseValueValid: boolean, nonNumericDefaultBaseValueReason: string? =
			ResourceValidator.ValidateResourceDefinition(nonNumericDefaultBaseValueDefinition, {})
		expect(isNonNumericDefaultBaseValueValid).toBe(false)
		expect(nonNumericDefaultBaseValueReason).toBe("ResourceMaxDefaultBaseValueMustBeNumber")
	end
)

it(
	"ResourceValidator.ValidateResourceDefinition rejects malformed regen definitions and negative regen rates",
	function()
		local nonTableRegenDefinition: ResourceDefinition = createValidResourceDefinition();
		(nonTableRegenDefinition :: any).regen = "fast"

		local isNonTableRegenValid: boolean, nonTableRegenReason: string? =
			ResourceValidator.ValidateResourceDefinition(nonTableRegenDefinition, {})
		expect(isNonTableRegenValid).toBe(false)
		expect(nonTableRegenReason).toBe("ResourceRegenMustBeTable")

		local missingRegenRateDefinition: ResourceDefinition = createValidResourceDefinition();
		(missingRegenRateDefinition :: any).regen = {}

		local isMissingRegenRateValid: boolean, missingRegenRateReason: string? =
			ResourceValidator.ValidateResourceDefinition(missingRegenRateDefinition, {})
		expect(isMissingRegenRateValid).toBe(false)
		expect(missingRegenRateReason).toBe("ResourceRegenRateMissing")

		local invalidRegenRateSourceDefinition: ResourceDefinition = createValidResourceDefinition();
		(invalidRegenRateSourceDefinition :: any).regen = {
			rate = {
				propertyName = "",
				defaultBaseValue = 5,
			},
		}

		local isInvalidRegenRateSourceValid: boolean, invalidRegenRateSourceReason: string? =
			ResourceValidator.ValidateResourceDefinition(invalidRegenRateSourceDefinition, {})
		expect(isInvalidRegenRateSourceValid).toBe(false)
		expect(invalidRegenRateSourceReason).toBe("ResourceRegenRatePropertyNameCannotBeEmpty")

		local negativeStaticRegenRateDefinition: ResourceDefinition = createValidResourceDefinition();
		(negativeStaticRegenRateDefinition :: any).regen = {
			rate = {
				value = -1,
			},
		}

		local isNegativeStaticRegenRateValid: boolean, negativeStaticRegenRateReason: string? =
			ResourceValidator.ValidateResourceDefinition(negativeStaticRegenRateDefinition, {})
		expect(isNegativeStaticRegenRateValid).toBe(false)
		expect(negativeStaticRegenRateReason).toBe("ResourceRegenRateCannotBeNegative")

		local negativePropertyBackedRegenRateDefinition: ResourceDefinition = createValidResourceDefinition();
		(negativePropertyBackedRegenRateDefinition :: any).regen = {
			rate = {
				propertyName = "StaminaRegen",
				defaultBaseValue = -5,
			},
		}

		local isNegativePropertyBackedRegenRateValid: boolean, negativePropertyBackedRegenRateReason: string? =
			ResourceValidator.ValidateResourceDefinition(negativePropertyBackedRegenRateDefinition, {})
		expect(isNegativePropertyBackedRegenRateValid).toBe(false)
		expect(negativePropertyBackedRegenRateReason).toBe("ResourceRegenRateCannotBeNegative")
	end
)

it(
	"ResourceValidator.ValidateResourceDefinition rejects definitions whose default max resolves below default min",
	function()
		local invalidBoundsDefinition: ResourceDefinition = createValidResourceDefinition();
		(invalidBoundsDefinition :: any).min = {
			propertyName = "MinStamina",
			defaultBaseValue = 25,
		}
		(invalidBoundsDefinition :: any).max = {
			propertyName = "MaxStamina",
			defaultBaseValue = 10,
		}

		local isInvalidBoundsValid: boolean, invalidBoundsReason: string? =
			ResourceValidator.ValidateResourceDefinition(invalidBoundsDefinition, {})
		expect(isInvalidBoundsValid).toBe(false)
		expect(invalidBoundsReason).toBe("ResourceDefaultMaxLessThanDefaultMin")
	end
)

it(
	"ResourceValidator.ValidateResourceDefinition rejects initialValue values outside default resolved bounds",
	function()
		local belowDefaultMinDefinition: ResourceDefinition = createValidResourceDefinition();
		(belowDefaultMinDefinition :: any).initialValue = -1

		local isBelowDefaultMinValid: boolean, belowDefaultMinReason: string? =
			ResourceValidator.ValidateResourceDefinition(belowDefaultMinDefinition, {})
		expect(isBelowDefaultMinValid).toBe(false)
		expect(belowDefaultMinReason).toBe("ResourceInitialValueLessThanDefaultMin")

		local aboveDefaultMaxDefinition: ResourceDefinition = createValidResourceDefinition();
		(aboveDefaultMaxDefinition :: any).initialValue = 101

		local isAboveDefaultMaxValid: boolean, aboveDefaultMaxReason: string? =
			ResourceValidator.ValidateResourceDefinition(aboveDefaultMaxDefinition, {})
		expect(isAboveDefaultMaxValid).toBe(false)
		expect(aboveDefaultMaxReason).toBe("ResourceInitialValueGreaterThanDefaultMax")
	end
)

it("ResourceValidator.ValidateResourceDefinition accepts minimal static resource definitions", function()
	local definition: ResourceDefinition = createValidResourceDefinition()

	local isValid: boolean, reason: string? = ResourceValidator.ValidateResourceDefinition(definition, {})

	expect(isValid).toBe(true)
	expect(reason).toBeNil()
end)

it("ResourceValidator.ValidateResourceDefinition accepts property-backed min, max, and regen sources", function()
	local definition: ResourceDefinition = createValidResourceDefinition();
	(definition :: any).min = {
		propertyName = "MinStamina",
		defaultBaseValue = 0,
	}
	(definition :: any).max = {
		propertyName = "MaxStamina",
		defaultBaseValue = 100,
	}
	(definition :: any).initialValue = 75
	(definition :: any).autoAssign = true
	(definition :: any).visibility = "ClientVisible"
	(definition :: any).regen = {
		rate = {
			propertyName = "StaminaRegen",
			defaultBaseValue = 12,
		},
	}

	local isValid: boolean, reason: string? = ResourceValidator.ValidateResourceDefinition(definition, {})

	expect(isValid).toBe(true)
	expect(reason).toBeNil()
end)
