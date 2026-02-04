local JestGlobals = require(game.ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local ReplicatedStorage = game:GetService("ReplicatedStorage")

it("mounts KRF package + expected folders", function()
	local Packages = ReplicatedStorage:WaitForChild("Packages")
	local KRF = Packages:FindFirstChild("KRF")

	expect(KRF).toBeDefined()
	expect(KRF:FindFirstChild("shared")).toBeDefined()
	expect(KRF:FindFirstChild("server")).toBeDefined()
	expect(KRF:FindFirstChild("client")).toBeDefined()
end)