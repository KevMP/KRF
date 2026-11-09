--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local afterEach: (() -> ()) -> () = (JestGlobals.afterEach :: unknown) :: (() -> ()) -> ()
local expect = JestGlobals.expect
local Types = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local Registry = require(KRF.client.Actor.utils.ActorViewRegistryState)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local fixture: Utils.Fixture? = nil
local originalObserve = Registry.ObserveInvalidation

afterEach(function()
	Registry.ObserveInvalidation = originalObserve

	if fixture ~= nil then
		Utils.destroy(fixture)
		fixture = nil
	end
end)

for _, failure: string in { "PrepareRefused", "CommitThrows", "AfterCommitThrows" } do
	it("clears Actor ownership and reports " .. failure .. " without retaining routes", function()
		local active: boolean = false

		local created: Utils.Fixture = Utils.new({
			Revision = Utils.stableRevision,
			HasActive = function(): boolean
				return active
			end,
			Prepare = function(): (Types.ActorSwitchRetirement?, string?)
				if failure == "PrepareRefused" then
					return nil, "InjectedRetirementRefused"
				end

				return {
					Commit = function(): ()
						if failure == "CommitThrows" then
							error("InjectedCommitFault", 0)
						end
					end,
					AfterCommit = function(): ()
						if failure == "AfterCommitThrows" then
							error("InjectedFollowUpFault", 0)
						end
					end,
				},
					nil
			end,
		})

		fixture = created
		Utils.set(created, { Utils.fixed() })
		Utils.select(created)
		active = true
		Registry.Invalidate(created.actor, "ActorRemoved")
		expect(created.owner.GetControlledActor()).toBeNil()
		expect(created.owner.GetProfileSources(created.actor)).toEqual({})

		expect(created.faults).toEqual({
			if failure == "PrepareRefused"
				then "InjectedRetirementRefused"
				elseif failure == "CommitThrows" then "ActorRetirementCommitFailed"
				else "ActorRetirementAfterCommitFailed",
		})
	end)
end

it("ignores a retained Actor invalidation callback after its owner is destroyed", function()
	local retained: ((ActorTypes.ActorView, string) -> ())? = nil

	Registry.ObserveInvalidation = function(callback): () -> ()
		retained = callback

		return originalObserve(callback)
	end

	local created: Utils.Fixture = Utils.new()
	fixture = created
	Registry.ObserveInvalidation = originalObserve
	Utils.select(created)
	created.owner.Destroy()
	assert(retained, "Expected owner invalidation callback")(created.actor, "ActorRemoved")
	expect(created.owner.GetControlledActor()).toBeNil()
	expect(created.faults).toEqual({})
end)

it(
	"releases an abandoned prepared Actor switch without invalidating the current Actor or leaking plan capacity",
	function()
		local created: Utils.Fixture = Utils.new()
		fixture = created
		Utils.select(created)

		for _ = 1, 64 do
			local plan: Types.PreparedActorSwitch =
				assert(created.owner.PrepareControlledActor(created.other), "Expected reusable plan capacity")

			created.owner.ReleaseControlledActor(plan)
			expect({ created.owner.CommitControlledActor(plan) }).toEqual({ false, "StaleActorSwitch" })
		end

		expect(created.owner.GetControlledActor()).toBe(created.actor)
	end
)
