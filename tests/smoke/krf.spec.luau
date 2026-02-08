local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

it("mounts KRF package + expected folders", function()
	local Packages = ReplicatedStorage:WaitForChild("Packages")
	local KRF = Packages:FindFirstChild("KRF")

	expect(KRF).toBeDefined()
	expect(KRF:FindFirstChild("shared")).toBeDefined()
	expect(KRF:FindFirstChild("server")).toBeDefined()
	expect(KRF:FindFirstChild("client")).toBeDefined()
end)
