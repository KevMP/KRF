--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.client.Action.types)
local InputTypes = require(ReplicatedStorage.Packages.KRF.client.Input.types)
local Owner = require(ReplicatedStorage.Packages.KRF.client.Action.ClientActionOwner)
local SequenceUtils = require(script.Parent.Utils.SequenceTestUtils)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

for _, dependency: string in { "Input", "Gesture", "Sequence", "Custom", "Gate" } do
	for _, location: string in { "Selected", "OtherActor", "Shadowed" } do
		it(
			"preflights prospective " .. dependency .. " removal for a " .. location .. " profile before native writes",
			function()
				expect({
					fixture.input.input.owner.SetSource("Recognition", {
						gestures = { X = { Tap = { maxDurationSeconds = 0.25 } } },
						sequences = { Combo = SequenceUtils.pattern({ "X" }) },
						recognizers = {
							Motion = SequenceUtils.recognizer(function(): InputTypes.CustomMatch?
								return nil
							end),
						},
					}),
				}).toEqual({ true })

				local key: Types.RouteKey = if dependency == "Sequence"
					then { kind = "Sequence", sequenceId = "Combo" }
					elseif dependency == "Custom" then { kind = "Custom", recognizerId = "Motion" }
					elseif dependency == "Gesture" then Utils.key("X", "Tap")
					else Utils.key()

				local route: Types.ActionRoute = Utils.fixed(key)

				if dependency == "Gate" then
					route.requiredContexts = { "Aim" }
				end

				local actor = if location == "OtherActor" then fixture.other else fixture.actor
				Utils.set(fixture, { route }, "Base", 0, actor)

				if location == "Shadowed" then
					Utils.set(fixture, { Utils.fixed(key, "Top.Action") }, "Top", 100)
				end

				Utils.select(fixture)
				local writes: number = #fixture.input.input.writes
				local sourceId: string = if dependency == "Input" or dependency == "Gate" then "Core" else "Recognition"

				-- Remove the recognition source first for Core so I1's own sequence
				-- dependency checks cannot accidentally stand in for the I4 validator.
				if sourceId == "Core" then
					expect({ fixture.input.input.owner.RemoveSource("Recognition") }).toEqual({ true })
				end

				writes = #fixture.input.input.writes

				expect({ fixture.input.input.owner.RemoveSource(sourceId) }).toEqual({
					false,
					"ProfileDependencyMissing",
				})

				expect(#fixture.input.input.writes).toBe(writes)
				expect(Utils.route(fixture, key, actor).status).toBe("Mapped")
			end
		)
	end
end

it("allows context enablement to gate routes without treating a disabled definition as missing", function()
	local route: Types.ActionRoute = Utils.fixed()
	route.requiredContexts = { "Aim" }
	Utils.set(fixture, { route })
	expect({ fixture.input.input.owner.SetContextEnabled("Aim", false) }).toEqual({ true })
	expect(Utils.route(fixture)).toEqual({ status = "Gated", candidateSources = { "Base" } })
	expect({ fixture.input.input.owner.SetContextEnabled("Aim", true) }).toEqual({ true })
	expect(Utils.route(fixture)).toMatchObject({ status = "Mapped" })
end)

it(
	"registers and disconnects exactly one validator, commit observer and envelope consumer per owner lifetime",
	function()
		fixture.owner.Destroy()
		local input: InputTypes.InputOwner = fixture.input.input.owner
		local additions: { string } = {}
		local removals: { string } = {}
		local registerValidator = input.RegisterGraphValidator
		local observeCommit = input.ObserveConfigurationCommit
		local observeEnvelope = input.ObserveCandidateEnvelope

		input.RegisterGraphValidator = function(callback: InputTypes.GraphValidator): () -> ()
			table.insert(additions, "Validator")
			local stop = registerValidator(callback)

			return function(): ()
				table.insert(removals, "Validator")
				stop()
			end
		end

		input.ObserveConfigurationCommit = function(callback: (InputTypes.InputGraphChange) -> ()): () -> ()
			table.insert(additions, "Commit")
			local stop = observeCommit(callback)

			return function(): ()
				table.insert(removals, "Commit")
				stop()
			end
		end

		input.ObserveCandidateEnvelope = function(callback: (InputTypes.InputCandidateEnvelope) -> ()): () -> ()
			table.insert(additions, "Envelope")
			local stop = observeEnvelope(callback)

			return function(): ()
				table.insert(removals, "Envelope")
				stop()
			end
		end

		fixture.owner = Owner.new(fixture.options)
		table.sort(additions)
		expect(additions).toEqual({ "Commit", "Envelope", "Validator" })
		Utils.set(fixture, { Utils.fixed() })
		fixture.owner.Destroy()
		fixture.owner.Destroy()
		table.sort(removals)
		expect(removals).toEqual({ "Commit", "Envelope", "Validator" })
		expect({ input.RemoveSource("Core") }).toEqual({ true })
		expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({})
	end
)

it("validates future compound removals against a prepared profile graph without publishing either graph", function()
	expect({ SequenceUtils.install(fixture.input, { Combo = SequenceUtils.pattern({ "X" }) }, "Recognition") }).toEqual({
		true,
	})

	local key: Types.RouteKey = { kind = "Sequence", sequenceId = "Combo" }
	Utils.set(fixture, { Utils.fixed(key) })
	expect({ fixture.input.input.owner.PrepareSource("Recognition", nil) }).toEqual({ nil, "ProfileDependencyMissing" })

	local profiles: Types.PreparedProfileGraph?, reason: string? =
		fixture.owner.PrepareProfiles({ { actor = fixture.actor, sourceId = "Base" } })

	expect(reason).toBeNil()
	expect(profiles).never.toBeNil()

	local input: InputTypes.PreparedInputUpdate?, rejection: string? =
		fixture.input.input.owner.PrepareSource("Recognition", nil, profiles)

	expect(rejection).toBeNil()
	expect(input).never.toBeNil()
	expect(Utils.route(fixture, key)).toMatchObject({ status = "Mapped" })
	expect(fixture.input.input.owner.GetSequence("Combo")).never.toBeNil()
	expect(fixture.transitions).toHaveLength(1)
end)

it("rejects stale input plans when the I4 validator generation is uninstalled", function()
	local plan: InputTypes.PreparedInputUpdate? = fixture.input.input.owner.PrepareSource("Empty", {})
	expect(plan).never.toBeNil()
	fixture.owner.Destroy()

	expect({ fixture.input.input.owner.CommitPrepared(assert(plan, "Expected prepared input plan")) }).toEqual({
		false,
		"StaleInputPlan",
	})
end)

it("rejects profile mutations during I1 preflight and commit without changing the installed profile", function()
	Utils.set(fixture, { Utils.fixed() })
	local results: { { any } } = {}

	local function mutate(): ()
		table.insert(results, { fixture.owner.SetProfileSource(fixture.actor, "New", { routes = { Utils.fixed() } }) })
		table.insert(results, { fixture.owner.RemoveProfileSource(fixture.actor, "Base") })
		table.insert(results, { fixture.owner.SetControlledActor(fixture.other) })
	end

	local stopValidator = fixture.input.input.owner.RegisterGraphValidator(function(): (boolean, string?)
		mutate()

		return true, nil
	end)

	local stopCommit = fixture.input.input.owner.ObserveConfigurationCommit(function()
		mutate()
	end)

	expect({ fixture.input.input.owner.SetContextEnabled("Aim", false) }).toEqual({ true })
	expect(#results >= 6).toBe(true)

	for _, result in results do
		expect(result).toEqual({ false, "DispatchInProgress" })
	end

	expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({
		{ sourceId = "Base", priority = 0, routeCount = 1 },
	})

	expect(fixture.owner.GetControlledActor()).toBeNil()
	stopValidator()
	stopCommit()
end)
