--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Action.types)
local ActorTypes = require(ReplicatedStorage.Packages.KRF.client.Actor.types)
local InputTypes = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local SequenceUtils = require(script.Parent.Utils.SequenceTestUtils)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local Registry = require(ReplicatedStorage.Packages.KRF.client.Actor.utils.ActorViewRegistryState)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("switches A B A with held input without phantom presses and rearms only after neutral", function()
	Utils.set(fixture, { Utils.fixed(nil, "ActorA.Action") })
	Utils.set(fixture, { Utils.fixed(nil, "ActorB.Action") }, "Base", nil, fixture.other)
	Utils.select(fixture)
	Utils.emit(fixture, 0)
	local original: Types.ActionRouteSelection = fixture.selections[1]
	Utils.select(fixture, fixture.other)
	expect(fixture.owner.GetControlledActor()).toBe(fixture.other)
	Utils.select(fixture)
	Utils.emit(fixture, 0.125)
	expect(Utils.actions(fixture)).toEqual({ "ActorA.Action" })
	Utils.emit(fixture, 0.25, "X", "Released")
	expect(Utils.actions(fixture)).toEqual({ "ActorA.Action" })
	Utils.emit(fixture, 0.375)
	expect(Utils.actions(fixture)).toEqual({ "ActorA.Action", "ActorA.Action" })
	expect(fixture.selections[2].selectionGeneration > original.selectionGeneration).toBe(true)
	expect(fixture.selections[2].holdOwner).never.toEqual(original.holdOwner)
end)

it("selects nil synchronously without disabling public recognition or withdrawing Actor profiles", function()
	expect({ SequenceUtils.install(fixture.input, { Combo = SequenceUtils.pattern({ "X" }) }) }).toEqual({ true })
	Utils.set(fixture, { Utils.fixed(), Utils.fixed({ kind = "Sequence", sequenceId = "Combo" }, "Combo") })
	Utils.select(fixture)
	expect({ fixture.owner.SetControlledActor(nil) }).toEqual({ true })
	expect(fixture.owner.GetControlledActor()).toBeNil()
	Utils.press(fixture, 0)
	expect(fixture.selections).toEqual({})
	expect(SequenceUtils.ids(fixture.input)).toEqual({ "Combo" })
	expect(#fixture.input.input.events).toBe(2)
	expect(Utils.route(fixture)).toMatchObject({ status = "Mapped" })
end)

it("treats selecting the same Actor as an idempotent no-op for input epochs and recognition history", function()
	expect({ SequenceUtils.install(fixture.input, { Combo = SequenceUtils.pattern({ "X", "Q" }) }) }).toEqual({ true })
	Utils.set(fixture, { Utils.fixed({ kind = "Sequence", sequenceId = "Combo" }, "Combo") })
	Utils.select(fixture)
	Utils.press(fixture, 0)
	local primitiveCount: number = #fixture.input.input.events
	expect({ fixture.owner.SetControlledActor(fixture.actor) }).toEqual({ true })
	expect(#fixture.input.input.events).toBe(primitiveCount)
	Utils.press(fixture, 0.125, "Q")
	expect(Utils.actions(fixture)).toEqual({ "Combo" })
end)

for _, collaborator: string in { "EpochPrepare", "RecognitionPrepare", "ActivationPrepare" } do
	it("preserves selection and recognition history when " .. collaborator .. " rejects preparation", function()
		local active: boolean = false

		if collaborator == "ActivationPrepare" then
			Utils.destroy(fixture)

			fixture = Utils.new({
				HasActive = function(): boolean
					return active
				end,
				Prepare = function(): (Types.ActorSwitchRetirement?, string?)
					return nil, "InjectedPrepareFailure"
				end,
			})
		end

		expect({ SequenceUtils.install(fixture.input, { Combo = SequenceUtils.pattern({ "X", "Q" }) }) }).toEqual({
			true,
		})

		Utils.set(fixture, { Utils.fixed({ kind = "Sequence", sequenceId = "Combo" }, "Combo") })
		Utils.select(fixture)
		Utils.press(fixture, 0)
		active = true

		if collaborator == "EpochPrepare" then
			fixture.input.input.owner.PrepareEpochInvalidation = function(): (
				InputTypes.PreparedInputInvalidation?,
				string?
			)
				return nil, "InjectedPrepareFailure"
			end
		elseif collaborator == "RecognitionPrepare" then
			fixture.input.input.owner.PrepareRecognitionReset = function(): (
				InputTypes.PreparedRecognitionReset?,
				string?
			)
				return nil, "InjectedPrepareFailure"
			end
		end

		expect({ fixture.owner.SetControlledActor(fixture.other) }).toEqual({ false, "InjectedPrepareFailure" })
		expect(fixture.owner.GetControlledActor()).toBe(fixture.actor)
		Utils.press(fixture, 0.125, "Q")
		expect(Utils.actions(fixture)).toEqual({ "Combo" })
	end)
end

for _, rejection: string in { "SwitchRevalidationRejected", "InputRuntimeFaulted" } do
	it(
		"preserves the old Actor, epoch and recognition history when commit revalidation rejects with " .. rejection,
		function()
			expect({ SequenceUtils.install(fixture.input, { Combo = SequenceUtils.pattern({ "X", "Q" }) }) }).toEqual({
				true,
			})

			Utils.set(fixture, { Utils.fixed(), Utils.fixed({ kind = "Sequence", sequenceId = "Combo" }, "Combo") })
			Utils.select(fixture)
			Utils.emit(fixture, 0)

			local hold: InputTypes.RecognitionHoldOwner =
				assert(fixture.selections[1].holdOwner, "Expected original live epoch")

			local graph: InputTypes.InputGraphSnapshot = fixture.input.input.owner.GetGraphSnapshot()
			local writes: number = #fixture.input.input.writes
			local events: number = #fixture.input.input.events
			table.clear(fixture.transitions)
			local validations: number = 0

			local stop = fixture.input.input.owner.RegisterGraphValidator(function(): (boolean, string?)
				validations += 1

				return validations ~= 2, if validations == 2 then rejection else nil
			end)

			local result: { any } = { fixture.owner.SetControlledActor(fixture.other) }
			stop()
			expect(result).toEqual({ false, rejection })
			expect(validations).toBe(2)
			expect(fixture.owner.GetControlledActor()).toBe(fixture.actor)
			expect(fixture.input.input.owner.GetGraphSnapshot()).toBe(graph)
			expect(#fixture.input.input.writes).toBe(writes)
			expect(#fixture.input.input.events).toBe(events)

			expect(fixture.input.input.owner.IsPressEpochActive(hold.inputId, hold.pressEpochId, hold.inputGeneration)).toBe(
				true
			)

			expect(fixture.transitions).toEqual({})
			expect(fixture.faults).toEqual({})
			Utils.press(fixture, 0.125, "Q")
			expect(Utils.actions(fixture)).toEqual({ "Combat.Punch", "Combo" })
			expect({ fixture.owner.SetControlledActor(fixture.other) }).toEqual({ true })
			expect(fixture.owner.GetControlledActor()).toBe(fixture.other)
		end
	)
end

it("fails closed when local activation retirement invalidates the destination before publication", function()
	local active: boolean = false
	local sends: number = 0
	Utils.destroy(fixture)

	fixture = Utils.new({
		HasActive = function(): boolean
			return active
		end,
		Prepare = function(): (Types.ActorSwitchRetirement?, string?)
			return {
				Commit = function(): ()
					active = false
					Registry.Remove(fixture.other)
				end,
				AfterCommit = function(): ()
					sends += 1
				end,
			},
				nil
		end,
	})

	Utils.set(fixture, { Utils.fixed() })
	Utils.set(fixture, { Utils.fixed(nil, "ActorB.Action") }, "Base", nil, fixture.other)
	Utils.select(fixture)
	Utils.emit(fixture, 0)

	local hold: InputTypes.RecognitionHoldOwner =
		assert(fixture.selections[1].holdOwner, "Expected original live epoch")

	table.clear(fixture.selections)
	table.clear(fixture.transitions)
	active = true

	expect({ fixture.owner.SetControlledActor(fixture.other) }).toEqual({ false, "ActorSwitchCommitFailed" })
	expect(Registry.IsCurrent(fixture.other)).toBe(false)
	expect(fixture.owner.GetControlledActor()).toBeNil()
	expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({})

	expect(fixture.input.input.owner.IsPressEpochActive(hold.inputId, hold.pressEpochId, hold.inputGeneration)).toBe(
		false
	)

	expect(sends).toBe(0)

	for _, change: Types.EffectiveRouteTransition in fixture.transitions do
		expect(change.reason == "ActorChanged" and change.next.status == "Mapped").toBe(false)
	end

	Utils.emit(fixture, 0.125, "X", "Released")
	Utils.press(fixture, 0.25)
	expect(fixture.selections).toEqual({})
	expect(fixture.input.input.connections > 0).toBe(true)
end)

it("rejects a missing required activation retirement guard instead of bypassing original activations", function()
	local active: boolean = false
	Utils.destroy(fixture)

	fixture = Utils.new({
		HasActive = function(): boolean
			return active
		end,
	})

	Utils.select(fixture)
	active = true
	expect({ fixture.owner.SetControlledActor(fixture.other) }).toEqual({ false, "ActivationGuardUnavailable" })
	expect(fixture.owner.GetControlledActor()).toBe(fixture.actor)
end)

it(
	"commits local epoch retirement and Actor selection before handing original activation intents downstream",
	function()
		local active: boolean = false
		local trace: { string } = {}
		local original: Types.ActionRouteSelection? = nil
		Utils.destroy(fixture)

		fixture = Utils.new({
			HasActive = function(): boolean
				return active
			end,
			Prepare = function(
				previous: ActorTypes.ActorView?,
				nextActor: ActorTypes.ActorView?
			): (Types.ActorSwitchRetirement?, string?)
				expect(previous).toBe(fixture.actor)
				expect(nextActor).toBe(fixture.other)
				table.insert(trace, "Prepare")

				return {
					Commit = function(): ()
						local captured: Types.ActionRouteSelection =
							assert(original, "Expected original activation metadata")

						local hold = assert(captured.holdOwner, "Expected original epoch")

						expect(
							fixture.input.input.owner.IsPressEpochActive(
								hold.inputId,
								hold.pressEpochId,
								hold.inputGeneration
							)
						).toBe(false)

						expect({ fixture.owner.SetControlledActor(nil) }).toEqual({ false, "DispatchInProgress" })
						table.insert(trace, "CommitLocal")
						active = false
					end,
					AfterCommit = function(): ()
						expect(fixture.owner.GetControlledActor()).toBe(fixture.other)
						expect(assert(original, "Expected original selection").actor).toBe(fixture.actor)
						table.insert(trace, "SendOriginalInterrupt")
					end,
				},
					nil
			end,
		})

		Utils.set(fixture, { Utils.fixed() })
		Utils.select(fixture)
		Utils.emit(fixture, 0)
		original = fixture.selections[1]
		active = true
		expect({ fixture.owner.SetControlledActor(fixture.other) }).toEqual({ true })
		expect(trace).toEqual({ "Prepare", "CommitLocal", "SendOriginalInterrupt" })
		expect(assert(original, "Expected retained original activation").actionId).toBe("Combat.Punch")
	end
)

for _, fault: string in
	{ "EpochCommit", "EpochCommitRejection", "EpochCommitFailed", "RecognitionCommit", "ActivationCommit" }
do
	it("clears selection and disarms routing safely after unexpected " .. fault .. " failure", function()
		local active: boolean = false
		local sends: number = 0

		if fault == "ActivationCommit" then
			Utils.destroy(fixture)

			fixture = Utils.new({
				HasActive = function(): boolean
					return active
				end,
				Prepare = function(): (Types.ActorSwitchRetirement?, string?)
					return {
						Commit = function(): ()
							error("InjectedCommitFault", 0)
						end,
						AfterCommit = function(): ()
							sends += 1
						end,
					},
						nil
				end,
			})
		end

		Utils.set(fixture, { Utils.fixed() })
		Utils.set(fixture, { Utils.fixed(nil, "ActorB.Action") }, "Base", nil, fixture.other)
		Utils.select(fixture)
		Utils.emit(fixture, 0)
		local original: Types.ActionRouteSelection = fixture.selections[1]
		table.clear(fixture.selections)
		active = true

		if fault == "EpochCommit" or fault == "EpochCommitRejection" or fault == "EpochCommitFailed" then
			fixture.input.input.owner.CommitEpochInvalidation = function(): (
				boolean,
				string?,
				InputTypes.InputCommitFailurePhase?
			)
				if fault == "EpochCommit" then
					error("InjectedCommitFault", 0)
				end

				if fault == "EpochCommitFailed" then
					return false, "NativeCommitFailed", "Failed"
				end

				return false, "UnclassifiedCommitFailure", nil
			end
		elseif fault == "RecognitionCommit" then
			fixture.input.input.owner.CommitPreparedRecognitionReset = function(): (boolean, string?)
				error("InjectedCommitFault", 0)
			end
		end

		expect({ fixture.owner.SetControlledActor(fixture.other) }).toEqual({ false, "ActorSwitchCommitFailed" })
		expect(fixture.owner.GetControlledActor()).toBeNil()
		Utils.emit(fixture, 0.125)
		Utils.emit(fixture, 0.25, "X", "Released")
		Utils.press(fixture, 0.375)
		expect(fixture.selections).toEqual({})
		local hold = assert(original.holdOwner, "Expected original held epoch")

		expect(fixture.input.input.owner.IsPressEpochActive(hold.inputId, hold.pressEpochId, hold.inputGeneration)).toBe(
			false
		)

		expect(sends).toBe(0)
	end)
end

for _, failure: string in { "Throw", "Yield" } do
	it("contains a retirement guard " .. failure .. " without publishing the new Actor", function()
		local active: boolean = false
		Utils.destroy(fixture)

		fixture = Utils.new({
			HasActive = function(): boolean
				return active
			end,
			Prepare = function(): (Types.ActorSwitchRetirement?, string?)
				if failure == "Throw" then
					error("GameRetirementFailure", 0)
				end

				coroutine.yield()

				return nil, nil
			end,
		})

		Utils.select(fixture)
		active = true

		expect({ fixture.owner.SetControlledActor(fixture.other) }).toEqual({
			false,
			if failure == "Throw" then "ActorSwitchGuardFailed" else "ActorSwitchGuardYielded",
		})

		expect(fixture.owner.GetControlledActor()).toBe(fixture.actor)
	end)
end

it("exposes the same prepared switch primitive for I7 and rejects stale, forged and reused plans", function()
	Utils.select(fixture)
	local plan: Types.PreparedActorSwitch?, reason: string? = fixture.owner.PrepareControlledActor(fixture.other)
	expect(reason).toBeNil()
	expect(plan).never.toBeNil()
	expect(fixture.owner.GetControlledActor()).toBe(fixture.actor)
	expect({ fixture.owner.CommitControlledActor({ token = {} }) }).toEqual({ false, "InvalidActorSwitch" })
	expect({ fixture.owner.CommitControlledActor(assert(plan, "Expected prepared selection")) }).toEqual({ true })
	expect(fixture.owner.GetControlledActor()).toBe(fixture.other)

	expect({ fixture.owner.CommitControlledActor(assert(plan, "Expected consumed plan")) }).toEqual({
		false,
		"StaleActorSwitch",
	})

	local stale: Types.PreparedActorSwitch? = fixture.owner.PrepareControlledActor(fixture.actor)
	Utils.set(fixture, { Utils.fixed() })

	expect({ fixture.owner.CommitControlledActor(assert(stale, "Expected stale prepared switch")) }).toEqual({
		false,
		"StaleActorSwitch",
	})
end)

for _, failure: string in { "HasActiveThrow", "HasActiveYield", "HasActiveMalformed", "MissingPlan", "MalformedPlan" } do
	it("rejects retirement preparation " .. failure .. " without altering the old selection", function()
		local active: boolean = false
		Utils.destroy(fixture)

		fixture = Utils.new({
			HasActive = function(): boolean
				if not active then
					return false
				end

				if failure == "HasActiveThrow" then
					error("Expected guard fault", 0)
				end

				if failure == "HasActiveYield" then
					coroutine.yield()
				end

				return if failure == "HasActiveMalformed" then "yes" :: any else true
			end,
			Prepare = function(): (Types.ActorSwitchRetirement?, string?)
				return if failure == "MissingPlan" then nil else { Commit = false } :: any, nil
			end,
		})

		Utils.select(fixture)
		active = true

		expect({ fixture.owner.SetControlledActor(fixture.other) }).toEqual({
			false,
			if failure == "HasActiveYield" then "ActorSwitchGuardYielded" else "ActorSwitchGuardFailed",
		})

		expect(fixture.owner.GetControlledActor()).toBe(fixture.actor)
	end)
end

for _, failure: string in { "Throw", "Yield" } do
	it("contains an AfterCommit " .. failure .. " after publishing the new local selection", function()
		local active: boolean = false
		Utils.destroy(fixture)

		fixture = Utils.new({
			HasActive = function(): boolean
				return active
			end,
			Prepare = function(): (Types.ActorSwitchRetirement?, string?)
				return {
					Commit = function(): ()
						active = false
					end,
					AfterCommit = function(): ()
						if failure == "Throw" then
							error("Expected post-commit fault", 0)
						end

						coroutine.yield()
					end,
				},
					nil
			end,
		})

		Utils.select(fixture)
		active = true
		expect({ fixture.owner.SetControlledActor(fixture.other) }).toEqual({ true })
		expect(fixture.owner.GetControlledActor()).toBe(fixture.other)
		expect(fixture.faults).toEqual({ "ActorSwitchAfterCommitFailed" })
	end)
end

it("rechecks prepared-switch availability and leaves old input state intact on rejection", function()
	Utils.select(fixture)
	local plan: Types.PreparedActorSwitch = assert(fixture.owner.PrepareControlledActor(fixture.other))

	fixture.ready = false
	expect({ fixture.owner.CommitControlledActor(plan) }).toEqual({ false, "ClientNotReady" })
	fixture.ready = true
	fixture.actors[2]:InstallUnavailable()
	expect({ fixture.owner.CommitControlledActor(plan) }).toEqual({ false, "ActorViewUnavailable" })
	expect(fixture.owner.GetControlledActor()).toBe(fixture.actor)
end)

it(
	"retires original activation context inside an authoritative Actor barrier before delivering follow-up intents",
	function()
		local active: boolean = false
		local trace: { string } = {}
		Utils.destroy(fixture)

		fixture = Utils.new({
			HasActive = function(): boolean
				return active
			end,
			Prepare = function(
				previous: ActorTypes.ActorView?,
				nextActor: ActorTypes.ActorView?
			): (Types.ActorSwitchRetirement?, string?)
				expect(previous).toBe(fixture.actor)
				expect(nextActor).toBeNil()
				table.insert(trace, "Prepare")

				return {
					Commit = function(): ()
						expect(fixture.owner.GetControlledActor()).toBeNil()
						table.insert(trace, "LocalRetirement")
						active = false
					end,
					AfterCommit = function(): ()
						expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({})
						table.insert(trace, "OriginalInterruptIntent")
					end,
				},
					nil
			end,
		})

		Utils.set(fixture, { Utils.fixed() })
		Utils.select(fixture)
		active = true
		Registry.Remove(fixture.actor)
		expect(trace).toEqual({ "Prepare", "LocalRetirement", "OriginalInterruptIntent" })
	end
)
