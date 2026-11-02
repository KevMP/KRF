--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.InputConstants)
local Value = require(script.Parent.InputValue)

type Owned<Definition> = { read sourceId: string, read definition: Definition }

type Configuration = {
	input: Types.InputSnapshot,
	Tap: Owned<Types.TapDefinition>?,
	Held: Owned<Types.HoldDefinition>?,
	LongHeld: Owned<Types.HoldDefinition>?,
	DoubleTapped: Owned<Types.DoubleTapDefinition>?,
	snapshots: { [Types.GestureKind]: Types.GestureSnapshot },
}

export type Plan = { [string]: Configuration }

type Pair = { definition: Owned<Types.DoubleTapDefinition>, policy: Types.DoubleTapArbitration }

type Press = {
	root: Types.PrimitiveOccurrence,
	Tap: Owned<Types.TapDefinition>?,
	Held: Owned<Types.HoldDefinition>?,
	LongHeld: Owned<Types.HoldDefinition>?,
	DoubleTapped: Owned<Types.DoubleTapDefinition>?,
	holdSources: { [string]: boolean },
	consumed: Pair?,
	cancelHeld: (() -> ())?,
	cancelLongHeld: (() -> ())?,
}

type Tap = {
	root: Types.PrimitiveOccurrence,
	press: Types.PrimitiveOccurrence,
	duration: number,
}

type History = {
	definition: Owned<Types.DoubleTapDefinition>,
	tap: Tap?,
	deadline: number,
	releasedAt: number,
	active: boolean,
	cancel: (() -> ())?,
}

export type Options = {
	Now: () -> number,
	Scheduler: Types.GestureScheduler,
	RunTimer: (callback: () -> ()) -> (),
	Deliver: (group: Types.GestureDispatchGroup, event: Types.GestureEvent?) -> (),
}

export type Owner = {
	Prepare: (graph: Types.InputGraphSnapshot) -> Plan,
	Commit: (plan: Plan, invalidated: { [string]: string }) -> (),
	Before: (occurrence: Types.PrimitiveOccurrence) -> (),
	Accept: (occurrence: Types.PrimitiveOccurrence) -> (),
	Get: (inputId: string) -> { [Types.GestureKind]: Types.GestureSnapshot }?,
	Revision: () -> number,
	Reset: (inputIds: { string }?) -> (),
	Destroy: () -> (),
}

local Recognition = {}

local function owned<Definition>(sourceId: string, definition: Definition, previous: Owned<Definition>?): Owned<Definition>
	if previous ~= nil and previous.sourceId == sourceId and Value.Equal(previous.definition, definition) then
		return previous
	end

	return table.freeze({ sourceId = sourceId, definition = definition })
end

-- A strictly later scheduler slot preserves the inclusive second-press boundary,
-- even when an injected wakeup arrives early or exactly at that boundary.
local function after(deadline: number): number
	return deadline + math.max(0.000001, math.abs(deadline) * 2 ^ -50)
end

function Recognition.new(options: Options): Owner
	local configurations: Plan = {}
	local presses: { [string]: Press } = {}
	local histories: { [string]: History } = {}
	local ordinal: number = 0
	local revision: number = 0
	local deadlines: number = 0
	local destroyed: boolean = false

	local function schedule(deadline: number, callback: () -> ()): () -> ()
		assert(deadlines < Constants.MAX_GESTURE_DEADLINES, "InputGestureDeadlineLimitExceeded")
		deadlines += 1
		local active: boolean = true

		local stop: () -> () = options.Scheduler.Schedule(deadline, function(): ()
			if not active or destroyed then
				return
			end

			active = false
			deadlines -= 1
			options.RunTimer(callback)
		end)

		return function(): ()
			if active then
				active = false
				deadlines -= 1
			end

			stop()
		end
	end

	local function retireHistory(inputId: string): ()
		local history: History? = histories[inputId]

		if history ~= nil then
			histories[inputId] = nil
			history.active = false

			if history.cancel ~= nil then
				history.cancel()
			end
		end
	end

	local function retirePress(inputId: string): ()
		local press: Press? = presses[inputId]

		if press ~= nil then
			presses[inputId] = nil

			if press.cancelHeld ~= nil then
				press.cancelHeld()
			end

			if press.cancelLongHeld ~= nil then
				press.cancelLongHeld()
			end
		end
	end

	local function candidate(
		key: string,
		root: Types.PrimitiveOccurrence,
		press: Types.PrimitiveOccurrence,
		eligible: boolean,
		timestamp: number,
		recognizedAt: number
	): Types.GestureCandidate
		return table.freeze({
			key = key,
			inputId = root.event.inputId,
			rootInputOrdinal = root.event.ordinal,
			generation = press.generation,
			pressEpochId = press.pressEpochId,
			routeEligible = eligible,
			timestamp = timestamp,
			recognizedAt = recognizedAt,
		})
	end

	local function deliver(
		root: Types.PrimitiveOccurrence,
		candidates: { Types.GestureCandidate },
		event: Types.GestureEvent?,
		policy: Types.DoubleTapArbitration?
	): ()
		if destroyed then
			return
		end

		local group: Types.GestureDispatchGroup = table.freeze({
			inputId = root.event.inputId,
			contextId = root.event.contextId,
			triggerInputOrdinal = root.event.ordinal,
			candidates = table.freeze(candidates),
			policy = policy,
		})

		options.Deliver(group, event)
	end

	local function emitTap(tap: Tap, eligible: boolean, policy: Types.DoubleTapArbitration?): ()
		ordinal += 1
		local timestamp: number = options.Now()

		local event: Types.TapGestureEvent = table.freeze({
			gesture = "Tap" :: "Tap",
			inputId = tap.root.event.inputId,
			contextId = tap.root.event.contextId,
			timestamp = timestamp,
			ordinal = ordinal,
			triggerInputOrdinal = tap.root.event.ordinal,
			pressDurationSeconds = tap.duration,
			recognizedAt = tap.root.event.timestamp,
		})

		deliver(
			tap.root,
			{ candidate("Tap", tap.root, tap.press, eligible, timestamp, event.recognizedAt) },
			event,
			policy
		)
	end

	local function expire(inputId: string, history: History): ()
		if histories[inputId] ~= history or not history.active then
			return
		end

		if options.Now() <= history.deadline then
			history.cancel = schedule(after(history.deadline), function(): ()
				expire(inputId, history)
			end)

			return
		end

		local tap: Tap? = history.tap
		retireHistory(inputId)
		revision += 1

		if tap ~= nil then
			emitTap(tap, true, "DeferredTap")
		end
	end

	local function settle(inputId: string, at: number): ()
		local press: Press? = presses[inputId]

		if press == nil then
			return
		end

		for _, kind: "Held" | "LongHeld" in { "Held", "LongHeld" } do
			local definition: Owned<Types.HoldDefinition>? = if kind == "Held" then press.Held else press.LongHeld

			if definition == nil or press.root.event.timestamp + definition.definition.afterSeconds > at then
				continue
			end

			if kind == "Held" then
				press.Held = nil

				if press.cancelHeld ~= nil then
					press.cancelHeld()
				end
			else
				press.LongHeld = nil

				if press.cancelLongHeld ~= nil then
					press.cancelLongHeld()
				end
			end

			press.holdSources[definition.sourceId] = true
			revision += 1
			ordinal += 1
			local timestamp: number = options.Now()

			local event: Types.HoldGestureEvent = table.freeze({
				gesture = kind,
				inputId = inputId,
				contextId = press.root.event.contextId,
				timestamp = timestamp,
				ordinal = ordinal,
				triggerInputOrdinal = press.root.event.ordinal,
				thresholdSeconds = definition.definition.afterSeconds,
				elapsedSeconds = timestamp - press.root.event.timestamp,
			})

			deliver(press.root, { candidate(kind, press.root, press.root, true, timestamp, timestamp) }, event, nil)

			if presses[inputId] ~= press or destroyed then
				break
			end
		end
	end

	local function start(occurrence: Types.PrimitiveOccurrence, configuration: Configuration): ()
		local inputId: string = occurrence.event.inputId
		local history: History? = histories[inputId]

		if history ~= nil and occurrence.event.timestamp > history.deadline then
			expire(inputId, history)
			history = nil
		end

		retirePress(inputId)

		local press: Press = {
			root = occurrence,
			Tap = configuration.Tap,
			Held = configuration.Held,
			LongHeld = configuration.LongHeld,
			DoubleTapped = configuration.DoubleTapped,
			holdSources = {},
		}

		presses[inputId] = press

		local candidates: { Types.GestureCandidate } = {}
		local event: Types.DoubleTapGestureEvent? = nil
		local policy: Types.DoubleTapArbitration? = nil

		if history ~= nil and history.definition == configuration.DoubleTapped then
			policy = history.definition.definition.arbitration or "PreferSpecific"
			press.consumed = { definition = history.definition, policy = policy }
			ordinal += 1

			event = table.freeze({
				gesture = "DoubleTapped" :: "DoubleTapped",
				inputId = inputId,
				contextId = occurrence.event.contextId,
				timestamp = options.Now(),
				ordinal = ordinal,
				triggerInputOrdinal = occurrence.event.ordinal,
				gapSeconds = occurrence.event.timestamp - history.releasedAt,
			})

			table.insert(
				candidates,
				candidate("DoubleTapped", occurrence, occurrence, true, event.timestamp, occurrence.event.timestamp)
			)

			retireHistory(inputId)
		end

		table.insert(
			candidates,
			candidate("Pressed", occurrence, occurrence, true, options.Now(), occurrence.event.timestamp)
		)

		for _, kind: "Held" | "LongHeld" in { "Held", "LongHeld" } do
			local definition: Owned<Types.HoldDefinition>? = if kind == "Held" then press.Held else press.LongHeld

			if definition == nil then
				continue
			end

			local function wake(): ()
				if presses[inputId] ~= press then
					return
				end

				local current = if kind == "Held" then press.Held else press.LongHeld

				if current ~= definition then
					return
				end

				settle(inputId, options.Now())
			end

			local cancel: () -> () = schedule(occurrence.event.timestamp + definition.definition.afterSeconds, wake)

			if kind == "Held" then
				press.cancelHeld = cancel
			else
				press.cancelLongHeld = cancel
			end
		end

		deliver(occurrence, candidates, event, policy)
	end

	local function release(occurrence: Types.PrimitiveOccurrence): ()
		local inputId: string = occurrence.event.inputId
		local press: Press? = presses[inputId]
		retirePress(inputId)

		if
			press == nil
			or press.root.pressEpochId ~= occurrence.pressEpochId
			or press.root.generation ~= occurrence.generation
		then
			deliver(occurrence, {}, nil, nil)

			return
		end

		local duration: number = occurrence.event.timestamp - press.root.event.timestamp
		local tapDefinition: Owned<Types.TapDefinition>? = press.Tap
		local tap: Tap? = nil

		if
			tapDefinition ~= nil
			and duration <= tapDefinition.definition.maxDurationSeconds
			and not (tapDefinition.definition.suppressIfHoldRecognized and press.holdSources[tapDefinition.sourceId])
		then
			tap = { root = occurrence, press = press.root, duration = duration }
		end

		local double: Owned<Types.DoubleTapDefinition>? = press.DoubleTapped
		local consumed: Pair? = press.consumed
		local policy: Types.DoubleTapArbitration? = if consumed ~= nil then consumed.policy else nil

		if double ~= nil and consumed == nil and duration <= double.definition.maxTapDurationSeconds then
			local deferred: boolean = double.definition.arbitration == "DeferredTap"

			local history: History = {
				definition = double,
				tap = if deferred then tap else nil,
				deadline = occurrence.event.timestamp + double.definition.maxGapSeconds,
				releasedAt = occurrence.event.timestamp,
				active = true,
			}

			retireHistory(inputId)
			histories[inputId] = history

			history.cancel = schedule(after(history.deadline), function(): ()
				expire(inputId, history)
			end)

			if deferred then
				tap = nil
			end
		end

		if
			consumed ~= nil
			and consumed.policy == "DeferredTap"
			and tapDefinition ~= nil
			and tapDefinition.sourceId == consumed.definition.sourceId
		then
			tap = nil
		end

		if tap ~= nil then
			emitTap(tap, policy ~= "PreferSpecific", policy)
		else
			deliver(occurrence, {}, nil, policy)
		end
	end

	local owner: Owner

	owner = {
		Prepare = function(graph: Types.InputGraphSnapshot): Plan
			local plan: Plan = {}

			for inputId: string, input: Types.InputSnapshot in graph.inputs do
				plan[inputId] = { input = input, snapshots = {} }
			end

			for _, sourceId: string in Value.Keys(graph.sources) do
				for inputId: string, definitions: Types.GestureDefinitions in graph.sources[sourceId].gestures or {} do
					local config: Configuration = plan[inputId]
					local previous: Configuration? = configurations[inputId]

					if definitions.Tap ~= nil then
						config.Tap = owned(sourceId, definitions.Tap, if previous ~= nil then previous.Tap else nil)
						config.snapshots.Tap = config.Tap
					end

					if definitions.Held ~= nil then
						config.Held = owned(sourceId, definitions.Held, if previous ~= nil then previous.Held else nil)
						config.snapshots.Held = config.Held
					end

					if definitions.LongHeld ~= nil then
						config.LongHeld =
							owned(sourceId, definitions.LongHeld, if previous ~= nil then previous.LongHeld else nil)

						config.snapshots.LongHeld = config.LongHeld
					end

					if definitions.DoubleTapped ~= nil then
						config.DoubleTapped = owned(
							sourceId,
							definitions.DoubleTapped,
							if previous ~= nil then previous.DoubleTapped else nil
						)

						config.snapshots.DoubleTapped = config.DoubleTapped
					end
				end
			end

			for _, config: Configuration in plan do
				table.freeze(config.snapshots)
				table.freeze(config)
			end

			return plan
		end,
		Commit = function(plan: Plan, invalidated: { [string]: string }): ()
			for inputId: string, previous: Configuration in configurations do
				local desired: Configuration? = plan[inputId]

				if invalidated[inputId] ~= nil or desired == nil then
					retirePress(inputId)
					retireHistory(inputId)
					continue
				end

				local pairChanged: boolean = (
					previous.DoubleTapped ~= desired.DoubleTapped or previous.Tap ~= desired.Tap
				)
					and (
						(previous.DoubleTapped ~= nil and previous.DoubleTapped.definition.arbitration == "DeferredTap")
						or (
							desired.DoubleTapped ~= nil
							and desired.DoubleTapped.definition.arbitration == "DeferredTap"
						)
					)

				if pairChanged or previous.DoubleTapped ~= desired.DoubleTapped then
					retireHistory(inputId)
				end

				local press: Press? = presses[inputId]

				if press ~= nil then
					if pairChanged or previous.Tap ~= desired.Tap then
						press.Tap = nil
					end

					if pairChanged or previous.DoubleTapped ~= desired.DoubleTapped then
						press.DoubleTapped = nil
						press.consumed = nil
					end

					if previous.Held ~= desired.Held then
						press.Held = nil

						if press.cancelHeld ~= nil then
							press.cancelHeld()
						end
					end

					if previous.LongHeld ~= desired.LongHeld then
						press.LongHeld = nil

						if press.cancelLongHeld ~= nil then
							press.cancelLongHeld()
						end
					end
				end
			end

			configurations = plan
		end,
		Before = function(occurrence: Types.PrimitiveOccurrence): ()
			if occurrence.event.kind == "Released" then
				settle(occurrence.event.inputId, occurrence.event.timestamp)
			elseif occurrence.event.kind == "Cancelled" then
				retirePress(occurrence.event.inputId)
				retireHistory(occurrence.event.inputId)
			end
		end,
		Accept = function(occurrence: Types.PrimitiveOccurrence): ()
			if destroyed or occurrence.event.inputType ~= Enum.InputActionType.Bool then
				return
			end

			revision += 1

			if occurrence.event.kind == "Pressed" then
				local config: Configuration? = configurations[occurrence.event.inputId]

				if config ~= nil then
					start(occurrence, config)
				end
			elseif occurrence.event.kind == "Released" then
				release(occurrence)
			else
				deliver(occurrence, {}, nil, nil)
			end
		end,
		Get = function(inputId: string): { [Types.GestureKind]: Types.GestureSnapshot }?
			local config: Configuration? = configurations[inputId]

			return if config ~= nil then config.snapshots else nil
		end,
		Revision = function(): number
			return revision
		end,
		Reset = function(inputIds: { string }?): ()
			revision += 1

			for _, inputId: string in inputIds or Value.Keys(configurations) do
				retirePress(inputId)
				retireHistory(inputId)
			end
		end,
		Destroy = function(): ()
			destroyed = true
			owner.Reset(nil)
			table.clear(configurations)
		end,
	}

	return owner
end

return Recognition
