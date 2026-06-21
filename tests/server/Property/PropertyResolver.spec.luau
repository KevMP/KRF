--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local KRF = ReplicatedStorage.Packages.KRF

local PropertyResolver = require(KRF.server.Property.utils.PropertyResolver)

type ModifierEntry = PropertyResolver.ModifierEntry

it("returns the base value when no modifiers are active", function()
	expect(PropertyResolver.Resolve(16, {})).toBe(16)
end)

it("applies add-only modifiers", function()
	local modifierEntries: { ModifierEntry } = {
		{
			modifier = {
				add = 4,
			},
			stackCount = 1,
		},
	}

	expect(PropertyResolver.Resolve(16, modifierEntries)).toBe(20)
end)

it("applies multiply-only modifiers", function()
	local modifierEntries: { ModifierEntry } = {
		{
			modifier = {
				multiply = 1.5,
			},
			stackCount = 1,
		},
	}

	expect(PropertyResolver.Resolve(10, modifierEntries)).toBe(15)
end)

it("applies add and multiply in the documented order", function()
	local modifierEntries: { ModifierEntry } = {
		{
			modifier = {
				add = 5,
			},
			stackCount = 1,
		},
		{
			modifier = {
				multiply = 2,
			},
			stackCount = 1,
		},
	}

	expect(PropertyResolver.Resolve(10, modifierEntries)).toBe(30)
end)

it("applies min-only modifiers", function()
	local modifierEntries: { ModifierEntry } = {
		{
			modifier = {
				min = 12,
			},
			stackCount = 1,
		},
	}

	expect(PropertyResolver.Resolve(10, modifierEntries)).toBe(12)
end)

it("applies max-only modifiers", function()
	local modifierEntries: { ModifierEntry } = {
		{
			modifier = {
				max = 25,
			},
			stackCount = 1,
		},
	}

	expect(PropertyResolver.Resolve(40, modifierEntries)).toBe(25)
end)

it("applies add, multiply, min, and max together through the normal path", function()
	local modifierEntries: { ModifierEntry } = {
		{
			modifier = {
				add = 5,
			},
			stackCount = 1,
		},
		{
			modifier = {
				multiply = 2,
			},
			stackCount = 1,
		},
		{
			modifier = {
				min = 12,
			},
			stackCount = 1,
		},
		{
			modifier = {
				max = 25,
			},
			stackCount = 1,
		},
	}

	expect(PropertyResolver.Resolve(10, modifierEntries)).toBe(25)
end)

it("sums multiple add modifiers and respects stack count", function()
	local modifierEntries: { ModifierEntry } = {
		{
			modifier = {
				add = 3,
			},
			stackCount = 2,
		},
		{
			modifier = {
				add = 4,
			},
			stackCount = 1,
		},
	}

	expect(PropertyResolver.Resolve(10, modifierEntries)).toBe(20)
end)

it("multiplies multiple multiply modifiers and respects stack count", function()
	local modifierEntries: { ModifierEntry } = {
		{
			modifier = {
				multiply = 1.5,
			},
			stackCount = 2,
		},
		{
			modifier = {
				multiply = 2,
			},
			stackCount = 1,
		},
	}

	expect(PropertyResolver.Resolve(10, modifierEntries)).toBe(45)
end)

it("uses the highest active minimum and the lowest active maximum", function()
	local modifierEntries: { ModifierEntry } = {
		{
			modifier = {
				min = 12,
			},
			stackCount = 1,
		},
		{
			modifier = {
				min = 15,
			},
			stackCount = 1,
		},
		{
			modifier = {
				max = 30,
			},
			stackCount = 1,
		},
		{
			modifier = {
				max = 25,
			},
			stackCount = 1,
		},
	}

	expect(PropertyResolver.Resolve(10, modifierEntries)).toBe(15)
	expect(PropertyResolver.Resolve(40, modifierEntries)).toBe(25)
end)

it("lets one active set modifier determine the final resolved value", function()
	local modifierEntries: { ModifierEntry } = {
		{
			modifier = {
				set = 8,
			},
			stackCount = 1,
		},
	}

	expect(PropertyResolver.Resolve(99, modifierEntries)).toBe(8)
end)

it("chooses the lowest active set value when multiple set modifiers are active", function()
	local modifierEntries: { ModifierEntry } = {
		{
			modifier = {
				set = 8,
			},
			stackCount = 1,
		},
		{
			modifier = {
				set = 5,
			},
			stackCount = 1,
		},
	}

	expect(PropertyResolver.Resolve(99, modifierEntries)).toBe(5)
end)

it("ignores add, multiply, min, and max when any active set modifier is present", function()
	local modifierEntries: { ModifierEntry } = {
		{
			modifier = {
				add = 100,
			},
			stackCount = 1,
		},
		{
			modifier = {
				multiply = 10,
			},
			stackCount = 1,
		},
		{
			modifier = {
				min = 50,
			},
			stackCount = 1,
		},
		{
			modifier = {
				max = 2,
			},
			stackCount = 1,
		},
		{
			modifier = {
				set = 9,
			},
			stackCount = 1,
		},
	}

	expect(PropertyResolver.Resolve(16, modifierEntries)).toBe(9)
end)

it("ignores later set, min, and max entries when they are not stronger than the current winner", function()
	local setEntries: { ModifierEntry } = {
		{
			modifier = {
				set = 5,
			},
			stackCount = 1,
		},
		{
			modifier = {
				set = 8,
			},
			stackCount = 1,
		},
	}
	local minEntries: { ModifierEntry } = {
		{
			modifier = {
				min = 15,
			},
			stackCount = 1,
		},
		{
			modifier = {
				min = 12,
			},
			stackCount = 1,
		},
	}
	local maxEntries: { ModifierEntry } = {
		{
			modifier = {
				max = 25,
			},
			stackCount = 1,
		},
		{
			modifier = {
				max = 30,
			},
			stackCount = 1,
		},
	}

	expect(PropertyResolver.Resolve(99, setEntries)).toBe(5)
	expect(PropertyResolver.Resolve(10, minEntries)).toBe(15)
	expect(PropertyResolver.Resolve(40, maxEntries)).toBe(25)
end)
