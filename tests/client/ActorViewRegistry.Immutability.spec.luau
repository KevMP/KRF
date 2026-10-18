--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local Types = require(KRF.client.Actor.types)
local Registry: Types.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)

for _, member: string in
	{
		"GetActorViewById",
		"GetActorViewByModel",
		"GetAllActorViews",
		"OnActorViewAdded",
		"OnActorViewRemoving",
	}
do
	for _, remove: boolean in { false, true } do
		it("rejects public registry mutation of " .. member .. " with removal=" .. tostring(remove), function()
			local untyped: any = Registry
			local original: any = untyped[member]

			local changed: boolean = pcall(function()
				untyped[member] = if remove then nil else function(): () end
			end)

			-- Restore the red-phase mutable scaffold before asserting, so a failure
			-- cannot corrupt the singleton used by unrelated specifications.
			if changed then
				untyped[member] = original
			end

			expect(changed).toBe(false)
			expect(untyped[member]).toBe(original)
		end)
	end
end

it("rejects new public registry members through an untyped reference", function()
	local untyped: any = Registry

	local changed: boolean = pcall(function()
		untyped.MutationProbe = true
	end)

	if changed then
		untyped.MutationProbe = nil
	end

	expect(changed).toBe(false)
end)
