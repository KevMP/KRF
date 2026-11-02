--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Input.types)
local Constants = require(KRF.client.Input.utils.InputConstants)
local TestUtils = require(script.Parent.Utils.InputTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("prepares a replacement without native allocation and consumes it exactly once", function()
	TestUtils.install(fixture)
	local before: number = #fixture.writes

	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.displayName = "Changed"
	local plan: Types.PreparedInputUpdate?, reason: string? = fixture.owner.PrepareSource("Core", definition)
	expect(reason).toBeNil()
	assert(plan ~= nil, "Expected prepared replacement")
	expect(table.isfrozen(plan)).toBe(true)
	expect(#fixture.writes).toBe(before)
	expect(fixture.owner.CommitPrepared(plan)).toBe(true)
	expect(assert(fixture.owner.GetInput("Primary"), "Expected input").displayName).toBe("Changed")
	expect({ fixture.owner.CommitPrepared(plan) }).toEqual({ false, "StaleInputPlan" })
	expect({ fixture.owner.CommitPrepared({ generation = 0, token = {} }) }).toEqual({ false, "InvalidInputPlan" })
end)

it("rejects invalid prepared sources without touching installed state", function()
	TestUtils.install(fixture)
	local before: number = #fixture.writes
	local plan: Types.PreparedInputUpdate?, reason: string? = fixture.owner.PrepareSource("", {})
	expect(plan).toBeNil()
	expect(reason).toBe("InvalidSourceId")
	plan, reason = fixture.owner.PrepareSource("Bad", false :: any)
	expect(plan).toBeNil()
	expect(reason).toBe("InvalidDefinition")

	plan, reason = fixture.owner.PrepareSource(
		"Bad",
		{ inputs = { Extra = { context = "Missing", type = Enum.InputActionType.Bool, bindings = {} } } }
	)

	expect(plan).toBeNil()
	expect(reason).toBe("UnknownContext")
	expect(#fixture.writes).toBe(before)
end)

it("rechecks dependent graphs on prepared commit and context enablement", function()
	TestUtils.install(fixture)
	local deny: boolean = false

	local stop: () -> () = fixture.owner.RegisterGraphValidator(function(): (boolean, string?)
		return not deny, if deny then "ReferencedByControlProfile" else nil
	end)

	local definition: TestUtils.CoreDefinition = TestUtils.definition()
	definition.inputs.Primary.displayName = "Changed"

	local plan: Types.PreparedInputUpdate? = fixture.owner.PrepareSource("Core", definition)
	assert(plan ~= nil, "Expected plan")
	local epochs: Types.PreparedInputInvalidation? = fixture.owner.PrepareEpochInvalidation("ActorChanged")
	assert(epochs ~= nil, "Expected epoch plan")
	deny = true
	expect({ fixture.owner.CommitPrepared(plan) }).toEqual({ false, "ReferencedByControlProfile" })

	expect({ fixture.owner.CommitEpochInvalidation(epochs, function()
		error("MustNotPublish")
	end) }).toEqual({ false, "ReferencedByControlProfile" })

	expect({ fixture.owner.SetContextEnabled("Gameplay", true) }).toEqual({ false, "ReferencedByControlProfile" })
	local rejected: Types.PreparedInputUpdate?, reason: string? = fixture.owner.PrepareSource("Core", definition)
	expect(rejected).toBeNil()
	expect(reason).toBe("ReferencedByControlProfile")
	local invalidation: Types.PreparedInputInvalidation?
	invalidation, reason = fixture.owner.PrepareEpochInvalidation("ActorChanged")
	expect(invalidation).toBeNil()
	expect(reason).toBe("ReferencedByControlProfile")
	stop()
	stop()
	expect(assert(fixture.owner.GetContext("Gameplay"), "Expected context").enabled).toBe(false)
end)

it("invalidates prepared work when validator registration changes", function()
	TestUtils.install(fixture)
	local plan: Types.PreparedInputUpdate? = fixture.owner.PrepareSource("Core", {})
	assert(plan ~= nil, "Expected plan")

	fixture.owner.RegisterGraphValidator(function()
		return true, nil
	end)

	expect({ fixture.owner.CommitPrepared(plan) }).toEqual({ false, "StaleInputPlan" })
	expect(assert(fixture.owner.GetInput("Primary"), "Expected input").sourceId).toBe("Core")
end)

it("bounds retained plans and rejects empty invalidation reasons", function()
	local plan: Types.PreparedInputInvalidation?, reason: string? = fixture.owner.PrepareEpochInvalidation("")
	expect(plan).toBeNil()
	expect(reason).toBe("InvalidInputInvalidationReason")
	local retained: { Types.PreparedInputInvalidation } = {}

	for _index: number = 1, Constants.MAX_PREPARED_PLANS do
		local nextPlan: Types.PreparedInputInvalidation? = fixture.owner.PrepareEpochInvalidation("ActorChanged")
		assert(nextPlan ~= nil, "Expected plan within budget")
		table.insert(retained, nextPlan)
	end

	plan, reason = fixture.owner.PrepareEpochInvalidation("ActorChanged")
	expect(plan).toBeNil()
	expect(reason).toBe("InputPlanLimitExceeded")
	expect(#retained).toBe(Constants.MAX_PREPARED_PLANS)
end)

it("rejects prepared operations during primitive delivery without touching the graph", function()
	TestUtils.install(fixture)
	TestUtils.enable(fixture)
	local plan: Types.PreparedInputUpdate? = fixture.owner.PrepareSource("Core", {})
	local epochs: Types.PreparedInputInvalidation? = fixture.owner.PrepareEpochInvalidation("ActorChanged")
	assert(plan ~= nil and epochs ~= nil, "Expected prepared plans")
	local results: { { any } } = {}

	fixture.owner.ObservePrimitive("Routing", function()
		table.insert(results, { fixture.owner.PrepareSource("Core", {}) })
		table.insert(results, { fixture.owner.PrepareEpochInvalidation("ActorChanged") })
		table.insert(results, { fixture.owner.CommitPrepared(plan) })

		table.insert(
			results,
			{ fixture.owner.CommitEpochInvalidation(epochs, function()
				error("MustNotPublish")
			end) }
		)
	end)

	TestUtils.emit(fixture, "Pressed", true)
	expect(results[1][2]).toBe("InputMutationReentrant")
	expect(results[2][2]).toBe("InputMutationReentrant")
	expect(results[3]).toEqual({ false, "InputMutationReentrant" })
	expect(results[4]).toEqual({ false, "InputMutationReentrant" })
	expect(fixture.faults).toEqual({})
end)

it("rejects all prepared and label operations after teardown", function()
	fixture.owner.Destroy()
	local plan: Types.PreparedInputUpdate?, reason: string? = fixture.owner.PrepareSource("Core", {})
	expect(plan).toBeNil()
	expect(reason).toBe("ClientNotReady")
	local epochs: Types.PreparedInputInvalidation?
	epochs, reason = fixture.owner.PrepareEpochInvalidation("ActorChanged")
	expect(epochs).toBeNil()
	expect(reason).toBe("ClientNotReady")
	expect({ fixture.owner.CommitPrepared({ generation = 0, token = {} }) }).toEqual({ false, "ClientNotReady" })
	local label: InputActionLabel = Instance.new("InputActionLabel")
	local bound: { any } = { fixture.owner.BindActionLabel("Primary", label) }
	local unbound: { any } = { fixture.owner.UnbindActionLabel(label) }
	label:Destroy()
	expect(bound).toEqual({ false, "ClientNotReady" })
	expect(unbound).toEqual({ false, "ClientNotReady" })
end)
