local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

local Game = ServerScriptService.Game

local function ids(definitions: { any }): { [string]: boolean }
	local seen: { [string]: boolean } = {}

	for _, definition in definitions do
		expect(type(definition.id)).toBe("string")
		expect(seen[definition.id]).toBeNil()
		seen[definition.id] = true
	end

	return seen
end

describe("definition catalogs", function()
	it("give every Property, Tag and Resource a unique id", function()
		for _, catalog in { "Properties", "Tags", "Resources" } do
			local folder = Game:FindFirstChild(catalog)

			if folder ~= nil then
				ids(require(folder) :: any)
			end
		end
	end)

	it("give every Action factory a unique id", function()
		local definitions = {}

		for _, factory in require(Game.Actions) :: any do
			table.insert(definitions, factory())
		end

		ids(definitions)
	end)
end)
