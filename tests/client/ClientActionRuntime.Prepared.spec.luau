--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local InputTypes = require(KRF.client.Input.types)
local Limits = require(KRF.client.Action.utils.ActionRouteLimits)
local SequenceUtils = require(script.Parent.Utils.SequenceTestUtils)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local Owner = require(KRF.client.Action.ClientActionOwner)
local InputUtils = require(script.Parent.Utils.InputTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("publishes a prepared profile-only change under the existing input fence without resetting a live epoch", function()
	Utils.set(fixture, { Utils.fixed() })
	Utils.select(fixture)
	Utils.emit(fixture, 0)

	local hold: InputTypes.RecognitionHoldOwner =
		assert(fixture.selections[1].holdOwner, "Expected original live epoch")

	local graph: InputTypes.InputGraphSnapshot = fixture.input.input.owner.GetGraphSnapshot()

	local profiles: Types.PreparedProfileGraph = assert(fixture.owner.PrepareProfiles({
		{
			actor = fixture.actor,
			sourceId = "Base",
			profile = { routes = { Utils.fixed(nil, "Combat.SwordSlash") } },
		},
	}))

	expect({ fixture.owner.CommitPreparedProfiles(profiles) }).toEqual({ false, "InputCommitFenceRequired" })
	local plan: InputTypes.PreparedInputUpdate = assert(fixture.input.input.owner.PrepareSource("Empty", {}, profiles))

	expect({
		fixture.input.input.owner.CommitPreparedWithPublication(plan, function(): ()
			expect(fixture.input.input.owner.IsCommitFenced()).toBe(true)
			local commit: InputTypes.InputCommitContext = assert(fixture.input.input.owner.GetCommitContext())
			expect(commit.previous).toBe(graph)
			expect(commit.invalidatedInputIds).toEqual({})
			expect({ fixture.owner.CommitPreparedProfiles(profiles) }).toEqual({ true })
			expect(Utils.route(fixture)).toMatchObject({ actionId = "Combat.SwordSlash" })
		end),
	}).toEqual({ true })

	expect(fixture.input.input.owner.GetGraphSnapshot()).toBe(graph)
	expect(fixture.input.input.owner.GetCommitContext()).toBeNil()

	expect(fixture.input.input.owner.IsPressEpochActive(hold.inputId, hold.pressEpochId, hold.inputGeneration)).toBe(
		true
	)

	expect(#fixture.input.input.events).toBe(1)
end)

it(
	"withdraws dependent profiles in the input commit before any configuration observer sees removed definitions",
	function()
		expect({ SequenceUtils.install(fixture.input, { Combo = SequenceUtils.pattern({ "X" }) }, "Recognition") }).toEqual({
			true,
		})

		local key: Types.RouteKey = { kind = "Sequence", sequenceId = "Combo" }
		Utils.set(fixture, { Utils.fixed(key) })
		Utils.set(fixture, { Utils.fixed(key) }, "Other", nil, fixture.other)

		local profiles: Types.PreparedProfileGraph = assert(fixture.owner.PrepareProfiles({
			{ actor = fixture.actor, sourceId = "Base" },
			{ actor = fixture.other, sourceId = "Other" },
		}))

		local plan: InputTypes.PreparedInputUpdate =
			assert(fixture.input.input.owner.PrepareSource("Recognition", nil, profiles))

		local observed: boolean = false

		local stop = fixture.input.input.owner.ObserveConfigurationCommit(function(): ()
			expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({})
			expect(fixture.owner.GetProfileSources(fixture.other)).toEqual({})
			expect(fixture.input.input.owner.GetSequence("Combo")).toBeNil()
			observed = true
		end)

		expect({
			fixture.input.input.owner.CommitPreparedWithPublication(plan, function(): ()
				expect({ fixture.owner.CommitPreparedProfiles(profiles) }).toEqual({ true })
			end),
		}).toEqual({ true })

		expect(observed).toBe(true)
		stop()
	end
)

it("prepares references to a prospective recognizer graph without making them live early", function()
	local graph: InputTypes.InputGraphSnapshot? = nil

	local stop = fixture.input.input.owner.RegisterGraphValidator(
		function(nextGraph: InputTypes.InputGraphSnapshot): (boolean, string?)
			graph = nextGraph

			return true, nil
		end
	)

	local definition: InputTypes.InputSourceDefinition = { sequences = { Combo = SequenceUtils.pattern({ "X" }) } }

	local preview: InputTypes.PreparedInputUpdate =
		assert(fixture.input.input.owner.PrepareSource("Recognition", definition))

	stop()
	fixture.input.input.owner.ReleasePrepared(preview)
	local key: Types.RouteKey = { kind = "Sequence", sequenceId = "Combo" }

	local profiles: Types.PreparedProfileGraph = assert(
		fixture.owner.PrepareProfiles(
			{ { actor = fixture.actor, sourceId = "Base", profile = { routes = { Utils.fixed(key, "Combo") } } } },
			assert(graph, "Expected prospective graph")
		)
	)

	expect(Utils.route(fixture, key)).toEqual({ status = "Unmapped" })

	local plan: InputTypes.PreparedInputUpdate =
		assert(fixture.input.input.owner.PrepareSource("Recognition", definition, profiles))

	expect({
		fixture.input.input.owner.CommitPreparedWithPublication(plan, function(): ()
			expect({ fixture.owner.CommitPreparedProfiles(profiles) }).toEqual({ true })
		end),
	}).toEqual({ true })

	Utils.select(fixture)
	Utils.press(fixture, 0)
	expect(Utils.actions(fixture)).toEqual({ "Combo" })
end)

it("rejects forged and stale prospective profile capabilities without removing live dependencies", function()
	Utils.set(fixture, { Utils.fixed() })

	expect({ fixture.input.input.owner.PrepareSource("Empty", {}, { token = {} }) }).toEqual({
		nil,
		"InvalidProfileGraph",
	})

	local profiles: Types.PreparedProfileGraph =
		assert(fixture.owner.PrepareProfiles({ { actor = fixture.actor, sourceId = "Base" } }))

	Utils.set(fixture, { Utils.fixed(Utils.key("Q")) }, "Other")
	expect({ fixture.input.input.owner.PrepareSource("Empty", {}, profiles) }).toEqual({ nil, "InvalidProfileGraph" })
	local plan: InputTypes.PreparedInputUpdate = assert(fixture.input.input.owner.PrepareSource("Empty", {}))
	local result: { any } = {}

	expect({
		fixture.input.input.owner.CommitPreparedWithPublication(plan, function(): ()
			result = { fixture.owner.CommitPreparedProfiles(profiles) }
		end),
	}).toEqual({ true })

	expect(result).toEqual({ false, "InvalidProfileGraph" })
	expect(Utils.route(fixture)).toMatchObject({ actionId = "Combat.Punch" })
end)

it("rejects a wrong prepared graph and disarms routing when its caller omits dependent profile publication", function()
	Utils.set(fixture, { Utils.fixed() })

	local profiles: Types.PreparedProfileGraph = assert(fixture.owner.PrepareProfiles({
		{ actor = fixture.other, sourceId = "Other", profile = { routes = { Utils.fixed() } } },
	}))

	local empty: InputTypes.PreparedInputUpdate = assert(
		fixture.input.input.owner.PrepareSource(
			"Core",
			nil,
			assert(fixture.owner.PrepareProfiles({ { actor = fixture.actor, sourceId = "Base" } }))
		)
	)

	local rejected: { any } = {}

	expect({
		fixture.input.input.owner.CommitPreparedWithPublication(empty, function(): ()
			rejected = { fixture.owner.CommitPreparedProfiles(profiles) }
		end),
	}).toEqual({ true })

	expect(rejected).toEqual({ false, "ProfileDependencyMissing" })
	expect(fixture.owner.GetControlledActor()).toBeNil()
	expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({})
	expect(fixture.faults).toEqual({ "ProfilePublicationMissing" })
end)

it("rejects reentrant prepared publication from its synchronous route observer", function()
	local profiles: Types.PreparedProfileGraph = assert(fixture.owner.PrepareProfiles({
		{ actor = fixture.actor, sourceId = "Base", profile = { routes = { Utils.fixed() } } },
	}))

	local plan: InputTypes.PreparedInputUpdate = assert(fixture.input.input.owner.PrepareSource("Empty", {}, profiles))
	local observed: { any } = {}

	fixture.owner.ObserveRoutes(function(): ()
		observed = { fixture.owner.CommitPreparedProfiles(profiles) }
	end)

	expect({
		fixture.input.input.owner.CommitPreparedWithPublication(plan, function(): ()
			expect({ fixture.owner.CommitPreparedProfiles(profiles) }).toEqual({ true })
		end),
	}).toEqual({ true })

	expect(observed).toEqual({ false, "DispatchInProgress" })
end)

for _, readiness: string in { "NotReady", "Destroyed" } do
	it("rejects both profile preparation and commit when " .. readiness, function()
		local profiles: Types.PreparedProfileGraph = assert(fixture.owner.PrepareProfiles({}))

		if readiness == "Destroyed" then
			fixture.owner.Destroy()
		else
			fixture.ready = false
		end

		expect({ fixture.owner.PrepareProfiles({}) }).toEqual({ nil, "ClientNotReady" })
		expect({ fixture.owner.CommitPreparedProfiles(profiles) }).toEqual({ false, "ClientNotReady" })
	end)
end

it("bounds retained profile proposals and reclaims all capabilities on a committed source change", function()
	local plans: { Types.PreparedProfileGraph } = {}

	for _ = 1, Limits.MAX_PREPARED_PLANS do
		local plan: Types.PreparedProfileGraph = assert(fixture.owner.PrepareProfiles({}))
		table.insert(plans, plan)
	end

	expect({ fixture.owner.PrepareProfiles({}) }).toEqual({ nil, "ActionPlanLimitExceeded" })
	Utils.set(fixture, { Utils.fixed() })
	local nextPlan: Types.PreparedProfileGraph?, reason: string? = fixture.owner.PrepareProfiles({})
	expect(reason).toBeNil()
	expect(nextPlan).never.toBeNil()
	expect(#plans).toBe(Limits.MAX_PREPARED_PLANS)
end)

it("compiles an entire prospective Actor graph before checking exchanged source priorities", function()
	Utils.set(fixture, { Utils.fixed(nil, "Base.Action") }, "Base", 0)
	Utils.set(fixture, { Utils.fixed(nil, "Sword.Action") }, "Sword", 100)
	table.clear(fixture.transitions)

	local profiles: Types.PreparedProfileGraph = assert(fixture.owner.PrepareProfiles({
		{
			actor = fixture.actor,
			sourceId = "Base",
			profile = { priority = 100, routes = { Utils.fixed(nil, "Base.Action") } },
		},
		{
			actor = fixture.actor,
			sourceId = "Sword",
			profile = { priority = 0, routes = { Utils.fixed(nil, "Sword.Action") } },
		},
	}))

	expect(Utils.route(fixture)).toMatchObject({ sourceId = "Sword", priority = 100 })
	local plan: InputTypes.PreparedInputUpdate = assert(fixture.input.input.owner.PrepareSource("Empty", {}, profiles))

	expect({
		fixture.input.input.owner.CommitPreparedWithPublication(plan, function(): ()
			expect({ fixture.owner.CommitPreparedProfiles(profiles) }).toEqual({ true })
		end),
	}).toEqual({ true })

	expect(Utils.route(fixture)).toMatchObject({ sourceId = "Base", priority = 100, shadowedSources = { "Sword" } })
	expect(#fixture.transitions).toBe(1)
	expect(fixture.transitions[1].previous).toMatchObject({ sourceId = "Sword" })
	expect(fixture.transitions[1].next).toMatchObject({ sourceId = "Base" })
end)

it("rejects malformed prospective updates without partially publishing a valid prefix", function()
	local invalid: { any } = {
		false,
		{ Extra = {} },
		{ [2] = {} },
		{ false },
		{ { actor = fixture.actor, sourceId = "" } },
		{ { sourceId = "Base" } },
		{ { actor = fixture.actor, sourceId = "Base", profile = { routes = { Utils.fixed(Utils.key("Missing")) } } } },
	}

	local reasons: { string } = {
		"InvalidProfileUpdates",
		"InvalidProfileUpdates",
		"InvalidProfileUpdates",
		"InvalidProfileUpdates",
		"InvalidProfileSourceId",
		"ActorViewUnavailable",
		"UnknownRouteInput",
	}

	for index: number, updates: any in invalid do
		expect({ fixture.owner.PrepareProfiles(updates) }).toEqual({ nil, reasons[index] })
	end

	expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({})
end)

it("rejects nil source replacement rather than withdrawing an installed contribution", function()
	Utils.set(fixture, { Utils.fixed() })

	expect({ fixture.owner.SetProfileSource(fixture.actor, "Base", nil :: any) }).toEqual({
		false,
		"InvalidControlProfile",
	})

	expect(Utils.route(fixture)).toMatchObject({ actionId = "Combat.Punch" })
end)

it("rejects a switch prepared before new recognition history without invalidating that history", function()
	expect({ SequenceUtils.install(fixture.input, { Combo = SequenceUtils.pattern({ "X", "Q" }) }) }).toEqual({ true })
	Utils.set(fixture, { Utils.fixed({ kind = "Sequence", sequenceId = "Combo" }, "Combo") })
	Utils.select(fixture)
	local plan: Types.PreparedActorSwitch = assert(fixture.owner.PrepareControlledActor(fixture.other))
	Utils.press(fixture, 0)
	expect({ fixture.owner.CommitControlledActor(plan) }).toEqual({ false, "StaleActorSwitch" })
	expect(fixture.owner.GetControlledActor()).toBe(fixture.actor)
	Utils.press(fixture, 0.125, "Q")
	expect(Utils.actions(fixture)).toEqual({ "Combo" })
end)

it(
	"installs initial recognition profiles together with the first input graph before any runtime graph existed",
	function()
		fixture.owner.Destroy()
		fixture.input.input.owner.Destroy()
		fixture.input.input = InputUtils.new()
		fixture.options.Input = fixture.input.input.owner
		fixture.owner = Owner.new(fixture.options)

		fixture.owner.ObserveRoutes(function(change: Types.EffectiveRouteTransition): ()
			table.insert(fixture.transitions, change)
		end)

		local core: InputTypes.InputSourceDefinition = InputUtils.definition()

		local definition: InputTypes.InputSourceDefinition = {
			contexts = core.contexts,
			inputs = core.inputs,
			sequences = { Combo = SequenceUtils.pattern({ "Primary" }) },
			recognizers = {
				Motion = {
					inputs = { "Primary" },
					maxWindowSeconds = 1,
					onEvent = function(): InputTypes.CustomMatch?
						return nil
					end,
				},
			},
		}

		local graph: InputTypes.InputGraphSnapshot? = nil

		local stop = fixture.input.input.owner.RegisterGraphValidator(
			function(nextGraph: InputTypes.InputGraphSnapshot): (boolean, string?)
				graph = nextGraph

				return true, nil
			end
		)

		local preview: InputTypes.PreparedInputUpdate =
			assert(fixture.input.input.owner.PrepareSource("Core", definition))

		stop()
		fixture.input.input.owner.ReleasePrepared(preview)

		local profiles: Types.PreparedProfileGraph = assert(fixture.owner.PrepareProfiles({
			{
				actor = fixture.actor,
				sourceId = "Base",
				profile = {
					routes = {
						Utils.fixed({ kind = "Sequence", sequenceId = "Combo" }),
						Utils.fixed({ kind = "Custom", recognizerId = "Motion" }),
					},
				},
			},
		}, assert(graph, "Expected prospective initial graph")))

		local plan: InputTypes.PreparedInputUpdate =
			assert(fixture.input.input.owner.PrepareSource("Core", definition, profiles))

		expect({
			fixture.input.input.owner.CommitPreparedWithPublication(plan, function(): ()
				expect({ fixture.owner.CommitPreparedProfiles(profiles) }).toEqual({ true })
			end),
		}).toEqual({ true })

		expect(#fixture.transitions).toBe(2)

		expect(fixture.owner.GetProfileSources(fixture.actor)).toEqual({
			{ sourceId = "Base", priority = 0, routeCount = 2 },
		})
	end
)
