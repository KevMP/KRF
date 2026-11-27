--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.client.Actor.types)
local Types = require(KRF.client.Presentation.types)
local ActorView: ActorTypes.ActorViewModule = require(KRF.client.Actor.ActorView)
local Eligibility = require(KRF.client.Presentation.utils.PresentationPredictionEligibility)
local StateUtils = require(script.Parent.Utils.PresentationStateTestUtils)
local PredictionUtils = require(script.Parent.Utils.PresentationPredictionTestUtils)

afterEach(function()
	StateUtils.reset()
end)

type Result = { estimate: Types.ActionPredictionEstimate, reason: string?, diagnostic: string? }

local function estimate(
	policy: Types.ActionPredictionPolicy,
	actor: ActorTypes.ActorView,
	ready: boolean?,
	measure: (() -> number)?
): Result
	local compiled: Types.CompiledActionPredictionPolicy = PredictionUtils.policies({ Fireball = policy }).Fireball

	local context: Types.ActionPredictionCheckContext =
		table.freeze({ actor = actor, actionId = "Fireball", originalStartKey = "1:1", parameters = { aim = 2 } })

	local value: Types.ActionPredictionEstimate, reason: string?, diagnostic: string? =
		Eligibility.Estimate(compiled, actor, ready ~= false, context, measure or function(): number
			return 0
		end)

	return { estimate = value, reason = reason, diagnostic = diagnostic }
end

local function anchor(value: number, min: number?, max: number?): any
	return { anchorValue = value, anchorTime = 0, min = min or 0, max = max or 100 }
end

it("allows an empty policy because no client check was declared", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	expect(estimate({}, actor.view, false)).toEqual({ estimate = "LikelyAllowed" })
end)

it("evaluates declared client-visible required and blocked Tags on the original view", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster", { ["Status.Grounded"] = { stackCount = 1 } })

	local policy: Types.ActionPredictionPolicy =
		{ requiredTags = { "Status.Grounded" }, blockedTags = { "Status.Stunned" } }

	expect(estimate(policy, actor.view)).toEqual({ estimate = "LikelyAllowed" })
	StateUtils.commit(actor.tags, { ["Status.Grounded"] = { stackCount = 1 }, ["Status.Stunned"] = { stackCount = 1 } })

	expect(estimate(policy, actor.view)).toEqual({
		estimate = "LikelyBlocked",
		reason = "BlockedTagPresent:Status.Stunned",
	})

	StateUtils.commit(actor.tags, {})

	expect(estimate(policy, actor.view)).toEqual({
		estimate = "LikelyBlocked",
		reason = "RequiredTagMissing:Status.Grounded",
	})
end)

it("cannot detect a server-only Tag because its absence looks identical to a missing Tag", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")

	expect(estimate({ blockedTags = { "Private.Silenced" } }, actor.view)).toEqual({ estimate = "LikelyAllowed" })
	expect(actor.view:GetTags():HasTag("Private.Silenced")).toBe(false)
end)

it("reports Unknown rather than a block while the view awaits a baseline, then evaluates once Ready", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster", nil, nil, { Mana = anchor(10) })
	local policy: Types.ActionPredictionPolicy = { requiredTags = { "Status.Grounded" }, costs = { Mana = 20 } }

	expect(estimate(policy, actor.view, false)).toEqual({ estimate = "Unknown", reason = "StateNotReady" })
	expect(estimate(policy, actor.view, true).estimate).toBe("LikelyBlocked")

	expect(estimate({ costs = { Mana = 5 } }, actor.view, false)).toEqual({
		estimate = "Unknown",
		reason = "StateNotReady",
	})

	expect(estimate({ costs = { Mana = 5 } }, actor.view, true)).toEqual({ estimate = "LikelyAllowed" })
end)

it("treats a missing Tags or Resources domain and an unassigned Resource as Unknown", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local stripped: ActorTypes.ActorViewOwner = assert(ActorView.new("Stripped", nil, {}))

	expect(estimate({ costs = { Mana = 5 } }, caster.view)).toEqual({
		estimate = "Unknown",
		reason = "ResourceUnavailable:Mana",
	})

	expect(estimate({ requiredTags = { "A" } }, stripped.view)).toEqual({
		estimate = "Unknown",
		reason = "TagsUnavailable",
	})

	expect(estimate({ costs = { Mana = 1 } }, stripped.view)).toEqual({
		estimate = "Unknown",
		reason = "ResourcesUnavailable",
	})

	stripped:Destroy()
end)

it("applies absolute and normalized percent thresholds with inclusive server bounds", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster", nil, nil, { Mana = anchor(30, 10, 50) })

	expect(estimate({ resourceRequirements = { Mana = { min = 30, max = 30 } } }, actor.view).estimate).toBe(
		"LikelyAllowed"
	)

	expect(estimate({ resourceRequirements = { Mana = { min = 31 } } }, actor.view)).toEqual({
		estimate = "LikelyBlocked",
		reason = "ResourceRequirementNotSatisfied:Mana",
	})

	expect(estimate({ resourceRequirements = { Mana = { minPercent = 0.5, maxPercent = 0.5 } } }, actor.view).estimate).toBe(
		"LikelyAllowed"
	)

	expect(estimate({ resourceRequirements = { Mana = { maxPercent = 0.49 } } }, actor.view).estimate).toBe(
		"LikelyBlocked"
	)

	StateUtils.commit(actor.resources, { Mana = anchor(10, 10, 10) })

	expect(estimate({ resourceRequirements = { Mana = { minPercent = 0 } } }, actor.view)).toEqual({
		estimate = "LikelyBlocked",
		reason = "ResourceRangeInvalid:Mana",
	})
end)

it("checks fixed, structured and percentage costs against the pre-spend base with inclusive affordability", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster", nil, nil, { Mana = anchor(30, 10, 50) })

	expect(estimate({ costs = { Mana = 20 } }, actor.view).estimate).toBe("LikelyAllowed")
	expect(estimate({ costs = { Mana = { amount = 20 } } }, actor.view).estimate).toBe("LikelyAllowed")

	expect(estimate({ costs = { Mana = 20.5 } }, actor.view)).toEqual({
		estimate = "LikelyBlocked",
		reason = "ResourceCostUnaffordable:Mana",
	})

	expect(estimate({ costs = { Mana = { percent = 0.5 } } }, actor.view).estimate).toBe("LikelyAllowed")
	expect(estimate({ costs = { Mana = { percent = 0.51 } } }, actor.view).estimate).toBe("LikelyBlocked")

	expect(estimate({ resourceRequirements = { Mana = { min = 30 } }, costs = { Mana = 20 } }, actor.view).estimate).toBe(
		"LikelyAllowed"
	)
end)

it("treats full and empty cooldown or shared charge Resources as ordinary Resources", function()
	local actor: StateUtils.Actor =
		StateUtils.actor("Caster", nil, nil, { ["Cooldown.Fireball"] = anchor(0, 0, 5), Charges = anchor(1, 0, 3) })

	local policy: Types.ActionPredictionPolicy = {
		resourceRequirements = { ["Cooldown.Fireball"] = { max = 0 } },
		costs = { Charges = 1 },
	}

	expect(estimate(policy, actor.view).estimate).toBe("LikelyAllowed")
	StateUtils.commit(actor.resources, { ["Cooldown.Fireball"] = anchor(5, 0, 5), Charges = anchor(1, 0, 3) })
	expect(estimate(policy, actor.view).reason).toBe("ResourceRequirementNotSatisfied:Cooldown.Fireball")
	StateUtils.commit(actor.resources, { ["Cooldown.Fireball"] = anchor(0, 0, 5), Charges = anchor(0, 0, 3) })
	expect(estimate(policy, actor.view).reason).toBe("ResourceCostUnaffordable:Charges")
end)

it("leaves a declared multiplier cost Unknown instead of guessing a Property value", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster", nil, nil, { Mana = anchor(100) })

	expect(estimate({ costs = { Mana = { amount = 1, multiplierProperty = "Haste" } } }, actor.view)).toEqual({
		estimate = "Unknown",
		reason = "ResourceCostMultiplierUnresolved:Mana",
	})
end)

it("reports a definitive block even when another declared gate is Unknown", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster", { ["Status.Stunned"] = { stackCount = 1 } })

	expect(estimate({ blockedTags = { "Status.Stunned" }, costs = { Mana = 1 } }, actor.view)).toEqual({
		estimate = "LikelyBlocked",
		reason = "BlockedTagPresent:Status.Stunned",
	})
end)

it("maps callback true, false and nil to allowed, blocked and Unknown with the original context", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local seen: { Types.ActionPredictionCheckContext } = {}

	local cases: { { decision: boolean?, estimate: Types.ActionPredictionEstimate } } = {
		{ decision = true, estimate = "LikelyAllowed" },
		{ decision = false, estimate = "LikelyBlocked" },
		{ decision = nil, estimate = "Unknown" },
	}

	for _, case in cases do
		local result: Result = estimate({
			canPredictStart = function(context: Types.ActionPredictionCheckContext): boolean?
				table.insert(seen, context)

				return case.decision
			end,
		}, actor.view)

		expect(result.estimate).toBe(case.estimate)
		expect(result.diagnostic).toBeNil()
	end

	expect(#seen).toBe(3)

	expect(seen[1]).toEqual({
		actor = actor.view,
		actionId = "Fireball",
		originalStartKey = "1:1",
		parameters = { aim = 2 },
	})

	expect(table.isfrozen(seen[1])).toBe(true)
end)

it("skips the callback once a declared gate is already a known block", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local calls: number = 0

	local result: Result = estimate({
		requiredTags = { "Status.Grounded" },
		canPredictStart = function(): boolean?
			calls += 1

			return true
		end,
	}, actor.view)

	expect(result.estimate).toBe("LikelyBlocked")
	expect(calls).toBe(0)
end)

it("fails closed to Unknown with a diagnostic when the callback errors, yields, returns junk or runs long", function()
	local actor: StateUtils.Actor = StateUtils.actor("Caster")
	local clock: number = 0

	local failing: { [string]: () -> any } = {
		["CallbackFailed:boom"] = function(): any
			error("boom", 0)
		end,
		CallbackYielded = function(): any
			task.wait()

			return true
		end,
		CallbackReturnInvalid = function(): any
			return "yes"
		end,
		CallbackOverBudget = function(): any
			clock += 0.006

			return true
		end,
	}

	for diagnostic: string, callback: () -> any in failing do
		local result: Result = estimate({ canPredictStart = callback :: any }, actor.view, true, function(): number
			return clock
		end)

		expect(result.estimate).toBe("Unknown")
		expect(result.diagnostic).toBe(diagnostic)
	end
end)

it("never mutates replicated Resource or Tag state while estimating", function()
	local actor: StateUtils.Actor = StateUtils.actor(
		"Caster",
		{ ["Status.Grounded"] = { stackCount = 1 } },
		nil,
		{ Mana = anchor(40) }
	)

	local tags: any = actor.tags.view:GetState()
	local resources: any = actor.resources.view:GetState()

	estimate({ requiredTags = { "Status.Grounded" }, costs = { Mana = 20 } }, actor.view)
	expect(actor.tags.view:GetState()).toBe(tags)
	expect(actor.resources.view:GetState()).toBe(resources)
	expect(actor.view:GetResources():GetCurrent("Mana")).toBe(40)
end)
