--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local Registry = require(KRF.client.Actor.utils.ActorViewRegistryState)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

for _, fail: boolean in { false, true } do
	it(
		"retires the original Actor only once when its switch retirement invalidates it, failure=" .. tostring(fail),
		function()
			Utils.destroy(fixture)
			local active: boolean = false
			local preparations: number = 0
			local commits: number = 0
			local intents: { { actor: ActorTypes.ActorView?, fenced: boolean } } = {}

			fixture = Utils.new({
				HasActive = function(): boolean
					return active
				end,
				Prepare = function(): (Types.ActorSwitchRetirement?, string?)
					preparations += 1

					return {
						Commit = function(): ()
							commits += 1
							Registry.Remove(fixture.actor)
							active = false

							if fail then
								error("Expected retirement failure", 0)
							end
						end,
						AfterCommit = function(): ()
							table.insert(intents, {
								actor = fixture.owner.GetControlledActor(),
								fenced = fixture.input.input.owner.IsCommitFenced(),
							})
						end,
					},
						nil
				end,
			})

			Utils.set(fixture, { Utils.fixed() })
			Utils.set(fixture, { Utils.fixed(nil, "ActorB.Action") }, "Base", nil, fixture.other)
			Utils.select(fixture)
			Utils.emit(fixture, 0)
			active = true

			expect({ fixture.owner.SetControlledActor(fixture.other) }).toEqual(
				if fail then { false, "ActorSwitchCommitFailed" } else { true }
			)

			expect({ preparations, commits }).toEqual({ 1, 1 })
			expect(intents).toEqual(if fail then {} else { { actor = fixture.other, fenced = false } })
			expect(Registry.IsCurrent(fixture.actor)).toBe(false)
			expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({})
			expect(fixture.owner.GetControlledActor()).toBe(if fail then nil else fixture.other)
		end
	)
end

it("commits selection before a route observer independently invalidates the published destination", function()
	Utils.set(fixture, { Utils.fixed() })
	Utils.set(fixture, { Utils.fixed(nil, "ActorB.Action") }, "Base", nil, fixture.other)
	Utils.select(fixture)
	local selectedAtNotification: ActorTypes.ActorView? = nil
	local trace: { string } = {}

	fixture.owner.ObserveRoutes(function(change: Types.EffectiveRouteTransition): ()
		if change.actor ~= fixture.other then
			return
		end

		if change.reason == "ActorChanged" and change.next.status == "Mapped" then
			selectedAtNotification = fixture.owner.GetControlledActor()
			table.insert(trace, "Published")
			Registry.Remove(fixture.other)
		elseif change.reason == "ActorRemoved" then
			table.insert(trace, "Removed")
		end
	end)

	expect({ fixture.owner.SetControlledActor(fixture.other) }).toEqual({ true })
	expect(selectedAtNotification).toBe(fixture.other)
	expect(trace).toEqual({ "Published", "Removed" })
	expect(fixture.owner.GetControlledActor()).toBeNil()
	expect(Registry.IsCurrent(fixture.other)).toBe(false)
	expect(fixture.owner.GetProfileSources(fixture.other)).toEqual({})
	expect({ fixture.owner.SetControlledActor(fixture.actor) }).toEqual({ true })
	Utils.press(fixture, 0)
	expect(Utils.actions(fixture)).toEqual({ "Combat.Punch" })
end)
