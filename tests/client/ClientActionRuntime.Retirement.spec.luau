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
local InputTypes = require(KRF.client.Input.types)
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
				Revision = Utils.stableRevision,
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
								fenced = fixture.input.input.owner.GetCommitContext() ~= nil,
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

for _, activeAtPreparation: boolean in { false, true } do
	it(
		"rejects a prepared switch when activations change without input changes, active="
			.. tostring(activeAtPreparation),
		function()
			Utils.destroy(fixture)
			local revision: number = 0
			local active: boolean = false
			local preparations: number = 0
			local commits: number = 0

			fixture = Utils.new({
				Revision = function(): number
					return revision
				end,
				HasActive = function(): boolean
					return active
				end,
				Prepare = function(): (Types.ActorSwitchRetirement?, string?)
					preparations += 1

					return {
						Commit = function(): ()
							commits += 1
						end,
						AfterCommit = function() end,
					},
						nil
				end,
			})

			Utils.set(fixture, { Utils.fixed() })
			Utils.set(fixture, { Utils.fixed(nil, "ActorB.Action") }, "Base", nil, fixture.other)
			Utils.select(fixture)
			active = activeAtPreparation
			local plan: Types.PreparedActorSwitch = assert(fixture.owner.PrepareControlledActor(fixture.other))
			active = true
			revision += 1

			expect({ fixture.owner.CommitControlledActor(plan) }).toEqual({ false, "StaleActorSwitch" })
			expect(commits).toBe(0)
			expect(fixture.owner.GetControlledActor()).toBe(fixture.actor)
			Utils.press(fixture, 0)
			expect(Utils.actions(fixture)).toEqual({ "Combat.Punch" })

			local preparedBefore: number = preparations
			expect({ fixture.owner.SetControlledActor(fixture.other) }).toEqual({ true })
			expect({ preparations, commits }).toEqual({ preparedBefore + 1, 1 })
			expect(fixture.owner.GetControlledActor()).toBe(fixture.other)
		end
	)
end

it("fails closed when activations change during the fenced recognition reset", function()
	Utils.destroy(fixture)
	local revision: number = 0
	local active: boolean = false
	local commits: number = 0

	fixture = Utils.new({
		Revision = function(): number
			return revision
		end,
		HasActive = function(): boolean
			return active
		end,
		Prepare = function(): (Types.ActorSwitchRetirement?, string?)
			return {
				Commit = function(): ()
					commits += 1
				end,
				AfterCommit = function() end,
			}, nil
		end,
	})

	Utils.set(fixture, { Utils.fixed() })
	Utils.select(fixture)
	active = true
	local input: InputTypes.InputOwner = fixture.input.input.owner
	local commitReset = input.CommitPreparedRecognitionReset

	input.CommitPreparedRecognitionReset = function(plan: InputTypes.PreparedRecognitionReset): (boolean, string?)
		revision += 1

		return commitReset(plan)
	end

	expect({ fixture.owner.SetControlledActor(fixture.other) }).toEqual({ false, "ActorSwitchCommitFailed" })
	expect(commits).toBe(0)
	expect(fixture.owner.GetControlledActor()).toBeNil()
end)

for _, phase: string in { "Prepare", "Commit" } do
	for _, failure: string in { "Throw", "Yield", "Malformed" } do
		it("keeps the old Actor when the activation revision read fails: " .. phase .. failure, function()
			Utils.destroy(fixture)
			local failing: boolean = false

			fixture = Utils.new({
				Revision = function(): number
					if failing and failure == "Throw" then
						error("Expected revision failure", 0)
					end

					if failing and failure == "Yield" then
						task.wait()
					end

					return if failing then "invalid" :: any else 0
				end,
				HasActive = function(): boolean
					return false
				end,
			})

			Utils.set(fixture, { Utils.fixed() })
			Utils.select(fixture)
			local expected: string = if failure == "Yield" then "ActorSwitchGuardYielded" else "ActorSwitchGuardFailed"

			if phase == "Prepare" then
				failing = true
				expect({ fixture.owner.PrepareControlledActor(fixture.other) }).toEqual({ nil, expected })
			else
				local plan: Types.PreparedActorSwitch = assert(fixture.owner.PrepareControlledActor(fixture.other))
				failing = true
				expect({ fixture.owner.CommitControlledActor(plan) }).toEqual({ false, expected })
			end

			expect(fixture.owner.GetControlledActor()).toBe(fixture.actor)
		end)
	end
end

it("stops a superseded transition before later observers when an observer invalidates its Actor", function()
	Utils.set(fixture, { Utils.fixed() })

	Utils.set(
		fixture,
		{ Utils.fixed(nil, "ActorB.Action"), Utils.fixed(Utils.key("Q"), "ActorB.Second") },
		"Base",
		nil,
		fixture.other
	)

	Utils.select(fixture)
	table.clear(fixture.transitions)
	local later: { string } = {}

	fixture.owner.ObserveRoutes(function(change: Types.EffectiveRouteTransition): ()
		if change.actor == fixture.other and change.reason == "ActorChanged" then
			Registry.Remove(fixture.other)
		end
	end)

	fixture.owner.ObserveRoutes(function(change: Types.EffectiveRouteTransition): ()
		if change.actor == fixture.other then
			table.insert(later, change.reason)
		end
	end)

	expect({ fixture.owner.SetControlledActor(fixture.other) }).toEqual({ true })
	expect(later).toEqual({ "ActorRemoved", "ActorRemoved" })
	local earlier: { string } = {}

	for _, change: Types.EffectiveRouteTransition in fixture.transitions do
		if change.actor == fixture.other then
			table.insert(earlier, change.reason)
		end
	end

	expect(earlier).toEqual({ "ActorChanged", "ActorRemoved", "ActorRemoved" })
end)

it("still delivers other routes in a batch when a nested transition supersedes one route", function()
	local gated: Types.ActionRoute = Utils.fixed(nil, "Gated.Before")
	gated.requiredContexts = { "Aim" }
	Utils.set(fixture, { gated, Utils.fixed(Utils.key("Q"), "Plain.Before") })
	local later: { string } = {}
	local toggled: boolean = false

	fixture.owner.ObserveRoutes(function(): ()
		if not toggled then
			toggled = true
			expect({ fixture.input.input.owner.SetContextEnabled("Aim", false) }).toEqual({ true })
		end
	end)

	fixture.owner.ObserveRoutes(function(change: Types.EffectiveRouteTransition): ()
		local key: any = change.key
		table.insert(later, key.inputId .. ":" .. change.next.status)
	end)

	local replacement: Types.ActionRoute = Utils.fixed(nil, "Gated.After")
	replacement.requiredContexts = { "Aim" }
	Utils.set(fixture, { replacement, Utils.fixed(Utils.key("Q"), "Plain.After") })

	expect(later).toEqual({ "X:Gated", "Q:Mapped" })
end)

it("stops selection delivery and handoff once an observer retires the selected Actor", function()
	Utils.set(fixture, { Utils.fixed() })
	Utils.select(fixture)
	local later: number = 0

	fixture.owner.ObserveSelection(function(): ()
		Registry.Remove(fixture.actor)
	end)

	fixture.owner.ObserveSelection(function(): ()
		later += 1
	end)

	Utils.emit(fixture, 0)
	expect(later).toBe(0)
	expect(fixture.selections).toEqual({})
end)
