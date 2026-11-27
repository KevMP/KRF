--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Presentation.types)
local Events = require(KRF.client.Presentation.PresentationEvents)
local States = require(KRF.client.Presentation.PresentationStates)
local HintState = require(KRF.client.Networking.utils.HintRuntimeState)
local ActorTypes = require(KRF.client.Actor.types)
local Actors: ActorTypes.ActorViewRegistryOwner = require(KRF.client.Actor.utils.ActorViewRegistryState)
local HintPolicyValidator = require(KRF.client.Presentation.HintPredictionPolicyValidator)
local StateUtils = require(script.Parent.Utils.PresentationStateTestUtils)
local PredictionUtils = require(script.Parent.Utils.PresentationPredictionTestUtils)

local HOLD_SECONDS: number = 0.5
local MATCH_WINDOW_SECONDS: number = 3

type Recorded = { contexts: { Types.PresentationContext } }

afterEach(function()
	StateUtils.reset()
end)

local function cast(recorded: Recorded): Types.PresentationDefinition
	return {
		id = "Fireball.Cast",
		entry = { event = Events.Action.Started, id = "Fireball" },
		predict = true,
		create = function(context: Types.PresentationContext)
			table.insert(recorded.contexts, context)
		end,
	}
end

local function impact(id: string, recorded: Recorded, predict: boolean?, hintId: string?): Types.PresentationDefinition
	return {
		id = id,
		entry = { event = Events.Hint.Received, id = hintId or "Fireball.Impact" },
		predict = predict,
		create = function(context: Types.PresentationContext)
			table.insert(recorded.contexts, context)
		end,
	}
end

local function install(definitions: { Types.PresentationDefinition }): PredictionUtils.Port
	local port: PredictionUtils.Port = PredictionUtils.port()

	local hintPolicies: Types.HintPredictionPolicyCatalog = assert(HintPolicyValidator.Compile({
		["Fireball.Impact"] = { actorIdField = "attackerId", sequenceIdField = "sequenceId" },
		["Fireball.Splash"] = { actorIdField = "attackerId", sequenceIdField = "sequenceId" },
	}))

	StateUtils.install(definitions, nil, PredictionUtils.policies({ Fireball = {} }), port.port, hintPolicies)

	return port
end

local function sources(recorded: Recorded): { string }
	local values: { string } = {}

	for _, context: Types.PresentationContext in recorded.contexts do
		table.insert(values, context.entry.source)
	end

	return values
end

local function predictedCast(
	port: PredictionUtils.Port,
	caster: StateUtils.Actor,
	casts: Recorded
): PredictionUtils.Start
	local start: PredictionUtils.Start = PredictionUtils.admit(port, caster.view, "Fireball", { aim = 1 })
	task.wait()
	expect(#casts.contexts).toBe(1)

	return start
end

local function serverImpact(target: StateUtils.Actor?, attackerId: string, sequenceId: number, hintId: string?): ()
	HintState.Notify({
		hintId = hintId or "Fireball.Impact",
		actorView = if target ~= nil then target.view else nil,
		payload = table.freeze({ attackerId = attackerId, sequenceId = sequenceId }),
	})
end

it("starts the predicted hit on the target in the same frame the cast calls PredictHint", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local hits: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", hits, true) })
	predictedCast(port, caster, casts)

	local payload: { [string]: number } = { strength = 3 }
	local predicted: boolean, reason: string? = casts.contexts[1]:PredictHint("Fireball.Impact", target.view, payload)
	payload.strength = 9
	task.wait()

	expect(predicted).toBe(true)
	expect(reason).toBeNil()
	expect(#hits.contexts).toBe(1)
	expect(hits.contexts[1].actor).toBe(target.view)

	expect(hits.contexts[1].entry).toEqual({
		source = "HintPrediction",
		event = "Received",
		actor = target.view,
		hintId = "Fireball.Impact",
		payload = { strength = 3 },
	})

	expect(table.isfrozen((hits.contexts[1].entry :: Types.PredictedHintEntry).payload)).toBe(true)
end)

it("skips the server's matching Hint for predicted definitions but still runs non-predicted ones", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local numbers: Recorded = { contexts = {} }

	local port: PredictionUtils.Port =
		install({ cast(casts), impact("Impact.Spark", sparks, true), impact("Impact.Damage", numbers, false) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)
	task.wait()
	serverImpact(target, "Caster", 4)
	task.wait()

	expect(sources(sparks)).toEqual({ "HintPrediction" })
	expect(sources(numbers)).toEqual({ "Hint" })
end)

it("holds a server Hint that arrives before Accepted and adopts it once the cast is accepted", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	serverImpact(target, "Caster", 4)
	task.wait()
	expect(#sparks.contexts).toBe(1)
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)
	task.wait()
	PredictionUtils.advance(port, HOLD_SECONDS)
	task.wait()

	expect(sources(sparks)).toEqual({ "HintPrediction" })
end)

it("releases a held server Hint after the hold window when the cast's reply never resolves", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Unknown")
	serverImpact(target, "Caster", 4)
	task.wait()
	expect(#sparks.contexts).toBe(1)
	PredictionUtils.advance(port, HOLD_SECONDS)
	task.wait()

	expect(sources(sparks)).toEqual({ "HintPrediction", "Hint" })
end)

it("plays Hints from other attackers, other activations and other targets normally", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local bystander: StateUtils.Actor = StateUtils.actor("Bystander")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)
	task.wait()
	serverImpact(target, "Teammate", 4)
	serverImpact(target, "Caster", 5)
	serverImpact(bystander, "Caster", 4)
	task.wait()

	expect(sources(sparks)).toEqual({ "HintPrediction", "Hint", "Hint", "Hint" })
	expect(sparks.contexts[4].actor).toBe(bystander.view)
end)

it("matches each server Hint to one predicted hit in order for a cast that hits a target repeatedly", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)
	task.wait()

	for _ = 1, 3 do
		serverImpact(target, "Caster", 4)
	end

	task.wait()

	expect(sources(sparks)).toEqual({ "HintPrediction", "HintPrediction", "Hint" })
end)

it("skips a later PredictHint when the server's Hint for that activation and target already played", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)
	task.wait()
	serverImpact(target, "Caster", 4)
	task.wait()

	local predicted: boolean, reason: string? = casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	task.wait()

	expect({ predicted, reason }).toEqual({ false, "HintAlreadyReceived" })
	expect(sources(sparks)).toEqual({ "Hint" })
	expect((casts.contexts[1]:PredictHint("Fireball.Impact", target.view))).toBe(true)
end)

it("stops waiting for a predicted hit's server Hint after the match window", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)
	task.wait()
	PredictionUtils.advance(port, MATCH_WINDOW_SECONDS)
	serverImpact(target, "Caster", 4)
	task.wait()

	expect(sources(sparks)).toEqual({ "HintPrediction", "Hint" })
end)

it("keeps the cast's correlation after its visuals finish until the predicted hit is matched", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	task.wait()
	sparks.contexts[1]:Finish()
	casts.contexts[1]:Finish()
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)
	PredictionUtils.started(caster.actions, "Fireball", 4)
	task.wait()
	serverImpact(target, "Caster", 4)
	task.wait()

	expect(sources(casts)).toEqual({ "ActionPrediction" })
	expect(sources(sparks)).toEqual({ "HintPrediction" })
end)

it("predicts an Actor-less Hint and matches the server's Actor-less receipt", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local casts: Recorded = { contexts = {} }
	local splashes: Recorded = { contexts = {} }

	local port: PredictionUtils.Port =
		install({ cast(casts), impact("Impact.Splash", splashes, true, "Fireball.Splash") })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	expect((casts.contexts[1]:PredictHint("Fireball.Splash", nil, { radius = 4 }))).toBe(true)
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)
	task.wait()
	serverImpact(nil, "Caster", 4, "Fireball.Splash")
	task.wait()

	expect(sources(splashes)).toEqual({ "HintPrediction" })
	expect(splashes.contexts[1].actor).toBeNil()
end)

it("refuses PredictHint with a stable reason when no predicted hit can start", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local others: Recorded = { contexts = {} }

	local port: PredictionUtils.Port =
		install({ cast(casts), impact("Impact.Spark", sparks, true), impact("Other", others, false, "Other") })

	local unavailable: StateUtils.Actor = StateUtils.actor("Gone")
	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	local context: Types.PresentationContext = casts.contexts[1]
	Actors.Invalidate(unavailable.view, "ActorRemoved")

	expect({ context:PredictHint("Other", target.view) }).toEqual({ false, "HintNotPredicted" })
	expect({ context:PredictHint("Fireball.Impact", unavailable.view) }).toEqual({ false, "ActorUnavailable" })
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Rejected", nil, "ActionNotGranted")
	task.wait()
	expect({ context:PredictHint("Fireball.Impact", target.view) }).toEqual({ false, "PredictionRejected" })
	context:Finish()
	expect({ context:PredictHint("Fireball.Impact", target.view) }).toEqual({ false, "InstanceInactive" })
	expect(#sparks.contexts).toBe(0)
end)

it("refuses PredictHint from an instance that was not started by a local prediction", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	install({ cast(casts), impact("Impact.Spark", sparks, true) })

	PredictionUtils.started(caster.actions, "Fireball", 4)
	task.wait()

	expect(casts.contexts[1].entry.source).toBe("Action")
	expect({ casts.contexts[1]:PredictHint("Fireball.Impact", target.view) }).toEqual({ false, "PredictionUnavailable" })
	expect(#sparks.contexts).toBe(0)
end)

it("rejects a PredictHint call without a nonempty Hint id", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local casts: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", { contexts = {} }, true) })
	predictedCast(port, caster, casts)

	local context: any = casts.contexts[1]

	expect(function()
		context:PredictHint("")
	end).toThrow("PredictHint: IdInvalid")

	expect(function()
		context:PredictHint("Fireball.Impact", "Dummy")
	end).toThrow("PredictHint: TargetInvalid")
end)

it("plays a server Hint whose payload does not carry the declared source fields", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)
	task.wait()
	HintState.Notify({ hintId = "Fireball.Impact", actorView = target.view, payload = 4 })
	task.wait()

	expect(sources(sparks)).toEqual({ "HintPrediction", "Hint" })
end)

it("lets a predicted hit watch its cast's LocalPrediction status to fade after a rejection", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local statuses: { string } = {}

	local spark: Types.PresentationDefinition = {
		id = "Impact.Spark",
		entry = { event = Events.Hint.Received, id = "Fireball.Impact" },
		predict = true,
		create = function(context: Types.PresentationContext)
			context:Watch(States.Action.LocalPrediction, function(snapshot: Types.LocalPredictionSnapshot)
				table.insert(statuses, snapshot.startStatus)
			end)
		end,
	}

	local port: PredictionUtils.Port = install({ cast(casts), spark })
	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	task.wait()
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Rejected", nil, "ActionNotGranted")
	task.wait()

	expect(statuses).toEqual({ "Admitted", "Rejected" })
end)

it("leaves predicted Hint definitions authoritative-only when no Action definition opts in to prediction", function()
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ impact("Impact.Spark", sparks, true) })

	serverImpact(target, "Caster", 4)
	task.wait()

	expect(sources(sparks)).toEqual({ "Hint" })
	expect(next(port.observers)).toBeNil()
end)

it("refuses PredictHint once the cast's reply horizon has passed", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	predictedCast(port, caster, casts)
	PredictionUtils.advance(port, 20)

	expect({ casts.contexts[1]:PredictHint("Fireball.Impact", target.view) }).toEqual({ false, "PredictionExpired" })
	expect(#sparks.contexts).toBe(0)
end)

it("bounds the predicted hits a single cast may wait on", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	predictedCast(port, caster, casts)

	for _ = 1, 16 do
		expect((casts.contexts[1]:PredictHint("Fireball.Impact", target.view))).toBe(true)
	end

	expect({ casts.contexts[1]:PredictHint("Fireball.Impact", target.view) }).toEqual({ false, "PredictedHintLimit" })
	task.wait()
	expect(#sparks.contexts).toBe(16)
end)

it("starts the server's Hint for a predicted definition the local hit could not claim", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local sounds: Recorded = { contexts = {} }

	local port: PredictionUtils.Port = install({
		cast(casts),
		impact("Impact.Spark", sparks, true),
		impact("Impact.Sound", sounds, true),
		{ id = "Flood", entry = { event = Events.Tag.Added, id = "Flood" }, create = function() end },
	})

	for _ = 1, 254 do
		caster.tags:FireEvent("Added", "Flood")
	end

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	expect((casts.contexts[1]:PredictHint("Fireball.Impact", target.view))).toBe(true)
	task.wait()
	expect(#sounds.contexts).toBe(0)
	sparks.contexts[1]:Finish()
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)
	task.wait()
	serverImpact(target, "Caster", 4)
	task.wait()

	expect(sources(sparks)).toEqual({ "HintPrediction" })
	expect(sources(sounds)).toEqual({ "Hint" })
end)

it("reports that no predicted hit started when every definition is refused", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }

	local port: PredictionUtils.Port = install({
		cast(casts),
		impact("Impact.Spark", sparks, true),
		{ id = "Flood", entry = { event = Events.Tag.Added, id = "Flood" }, create = function() end },
	})

	for _ = 1, 255 do
		caster.tags:FireEvent("Added", "Flood")
	end

	predictedCast(port, caster, casts)

	expect({ casts.contexts[1]:PredictHint("Fireball.Impact", target.view) }).toEqual({ false, "PredictionNotStarted" })
	StateUtils.reset()
end)

it("remembers a server Hint that arrives before the reply so a later PredictHint does not play it twice", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	serverImpact(target, "Caster", 4)
	serverImpact(target, "Caster", 5)
	task.wait()
	expect(sources(sparks)).toEqual({ "Hint", "Hint" })
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)
	task.wait()

	expect({ casts.contexts[1]:PredictHint("Fireball.Impact", target.view) }).toEqual({ false, "HintAlreadyReceived" })
	expect((casts.contexts[1]:PredictHint("Fireball.Impact", target.view))).toBe(true)
	task.wait()
	expect(sources(sparks)).toEqual({ "Hint", "Hint", "HintPrediction" })
end)

it("releases a held server Hint as soon as the cast is Rejected", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	serverImpact(target, "Caster", 4)
	task.wait()
	expect(#sparks.contexts).toBe(1)
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Rejected", nil, "ActionNotGranted")
	task.wait()

	expect(sources(sparks)).toEqual({ "HintPrediction", "Hint" })
end)

it("releases a held server Hint on its target when the attacking Actor retires", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	predictedCast(port, caster, casts)
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	serverImpact(target, "Caster", 4)
	task.wait()
	expect(#sparks.contexts).toBe(1)
	Actors.Invalidate(caster.view, "ActorRemoved")
	task.wait()

	expect(sources(sparks)).toEqual({ "HintPrediction", "Hint" })
	expect(sparks.contexts[2].actor).toBe(target.view)
end)

it("evicts an idle cast without waiting hits before one whose predicted hit is still waiting", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	task.wait()
	sparks.contexts[1]:Finish()
	casts.contexts[1]:Finish()
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)

	for _ = 1, 32 do
		PredictionUtils.admit(port, caster.view, "Fireball", { aim = 1 })
		task.wait()
		casts.contexts[#casts.contexts]:Finish()
	end

	task.wait()
	serverImpact(target, "Caster", 4)
	task.wait()

	expect(sources(sparks)).toEqual({ "HintPrediction" })
end)

it("refuses PredictHint from a predicted hit so only the cast predicts hits", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	predictedCast(port, caster, casts)
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	task.wait()

	expect({ sparks.contexts[1]:PredictHint("Fireball.Impact", target.view) }).toEqual({
		false,
		"PredictionUnavailable",
	})
end)

it("forgets a server Hint that arrived before the reply once the match window passes", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	serverImpact(target, "Caster", 4)
	task.wait()
	PredictionUtils.advance(port, MATCH_WINDOW_SECONDS)
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)
	task.wait()

	expect((casts.contexts[1]:PredictHint("Fireball.Impact", target.view))).toBe(true)
	task.wait()
	expect(sources(sparks)).toEqual({ "Hint", "HintPrediction" })
end)

it("pairs an early server Hint with a hit predicted before the reply so a later Hint still plays", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)
	serverImpact(target, "Caster", 4)
	task.wait()
	casts.contexts[1]:PredictHint("Fireball.Impact", target.view)
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)
	task.wait()
	serverImpact(target, "Caster", 4)
	task.wait()

	expect(sources(sparks)).toEqual({ "Hint", "HintPrediction", "Hint" })
end)

it("bounds the server Hints remembered before a reply", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	local start: PredictionUtils.Start = predictedCast(port, caster, casts)

	for _ = 1, 9 do
		serverImpact(target, "Caster", 4)
	end

	task.wait()
	PredictionUtils.outcome(port, caster.view, "Fireball", start, "Accepted", 4)
	task.wait()

	for _ = 1, 8 do
		expect({ casts.contexts[1]:PredictHint("Fireball.Impact", target.view) }).toEqual({
			false,
			"HintAlreadyReceived",
		})
	end

	expect((casts.contexts[1]:PredictHint("Fireball.Impact", target.view))).toBe(true)
end)

it("drops remembered early Hints with the attacking Actor and at shutdown", function()
	local caster: StateUtils.Actor = StateUtils.actor("Caster")
	local other: StateUtils.Actor = StateUtils.actor("Other")
	local target: StateUtils.Actor = StateUtils.actor("Dummy")
	local casts: Recorded = { contexts = {} }
	local sparks: Recorded = { contexts = {} }
	local port: PredictionUtils.Port = install({ cast(casts), impact("Impact.Spark", sparks, true) })

	predictedCast(port, caster, casts)
	PredictionUtils.admit(port, other.view, "Fireball", { aim = 1 })
	task.wait()
	serverImpact(target, "Caster", 4)
	serverImpact(target, "Other", 7)
	task.wait()
	Actors.Invalidate(caster.view, "ActorRemoved")
	task.wait()
	StateUtils.reset()

	expect(sources(sparks)).toEqual({ "Hint", "Hint" })
	expect(#port.delays > 0).toBe(true)

	for _, scheduled: PredictionUtils.Delay in port.delays do
		expect(scheduled.cancelled).toBe(true)
	end
end)
