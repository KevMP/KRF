--!strict
local Types = require(script.Parent.Parent.types)
local Value = require(script.Parent.InputValue)
local Observers = require(script.Parent.Parent.Parent.Parent.shared.Signal.PrivateObservers)
local ScalarState = require(script.Parent.InputRecognizerState)
local DeadlineTimer = require(script.Parent.InputDeadlineTimer)

type Entry = {
	snapshot: Types.RecognizerSnapshot,
	state: ScalarState.Store,
	horizon: number?,
	deadline: number?,
	timer: DeadlineTimer.Owner,
	context: Types.RecognizerContext,
	live: boolean,
	cancelling: boolean,
	violation: string?,
	cause: number?,
	lastOutput: number?,
}

export type Options = {
	Now: () -> number,
	Schedule: (number, () -> ()) -> () -> (),
	Emit: (string, Types.CustomMatch, number?, number?) -> (),
	Fault: (string) -> (),
	Report: (string) -> (),
	Changed: () -> (),
}

export type Owner = {
	Commit: (Types.RecognitionCatalog?, { [string]: string }, { [string]: boolean }) -> (),
	Accept: (Types.RecognizerEvent, string, number, Types.RecognitionToken) -> (),
	Before: () -> (),
	Watches: (string) -> boolean,
	Reset: ({ string }?) -> (),
	Get: (string) -> Types.RecognizerSnapshot?,
	Destroy: () -> (),
}

local Custom = {}

function Custom.new(options: Options): Owner
	local entries: { [string]: Entry } = {}
	local index: { [string]: { string } } = {}
	local active: { [string]: Entry } = {}
	local destroyed: boolean = false
	local owner: Owner
	local arm: (Entry) -> ()
	local settle: (string, Entry) -> ()

	local function retire(id: string, entry: Entry): ()
		options.Changed()
		entry.timer.Cancel()
		entry.state = ScalarState.new()
		entry.horizon = nil
		entry.deadline = nil
		entry.cause = nil
		active[id] = nil
	end

	local function fault(id: string, entry: Entry, reason: string): ()
		retire(id, entry)

		entry.snapshot = table.freeze({
			recognizerId = id,
			sourceId = entry.snapshot.sourceId,
			definition = entry.snapshot.definition,
			faulted = true,
			faultReason = string.sub(reason, 1, 512),
		})

		options.Fault(id)
		options.Report("InputRecognizer:" .. id .. ":" .. string.sub(reason, 1, 512))
	end

	-- One context per entry: callbacks are never reentrant, and `live` keeps a
	-- retained context unusable outside the callback that received it.
	local function create(id: string, snapshot: Types.RecognizerSnapshot): Entry
		local entry: Entry

		local context: Types.RecognizerContext = table.freeze({
			GetState = function(_self: Types.RecognizerContext, key: string): Types.RecognitionScalar?
				assert(entry.live, "InactiveRecognizerContext")

				local value: Types.RecognitionScalar?, reason: string? = ScalarState.Get(entry.state, key)

				if reason ~= nil then
					entry.violation = reason
				end

				return value
			end,
			SetState = function(
				_self: Types.RecognizerContext,
				key: string,
				value: Types.RecognitionScalar?
			): (boolean, string?)
				assert(entry.live, "InactiveRecognizerContext")
				local success: boolean, reason: string? = ScalarState.Set(entry.state, key, value)

				if not success then
					entry.violation = reason
				end

				return success, reason
			end,
			Now = function(_self: Types.RecognizerContext): number
				assert(entry.live, "InactiveRecognizerContext")

				return options.Now()
			end,
			ScheduleAfter = function(_self: Types.RecognizerContext, seconds: number): (boolean, string?)
				assert(entry.live, "InactiveRecognizerContext")

				if not Value.IsFinite(seconds) or seconds <= 0 then
					entry.violation = "InvalidRecognizerDeadline"

					return false, "InvalidRecognizerDeadline"
				end

				-- Cancellation retires this window, and a graph commit may already
				-- have done so. Nothing is left to schedule, but that is not a fault.
				if entry.cancelling then
					return false, "RecognizerCancelled"
				end

				local deadline: number = options.Now() + seconds

				if entry.horizon == nil or deadline > entry.horizon then
					entry.violation = "RecognizerWindowExceeded"

					return false, "RecognizerWindowExceeded"
				end

				entry.deadline = deadline

				return true, nil
			end,
			ClearDeadline = function(_self: Types.RecognizerContext): ()
				assert(entry.live, "InactiveRecognizerContext")
				entry.deadline = nil
			end,
		})

		entry = {
			snapshot = snapshot,
			state = ScalarState.new(),
			context = context,
			live = false,
			cancelling = false,
			timer = DeadlineTimer.new(options.Schedule, function(): ()
				if not destroyed and entries[id] == entry then
					settle(id, entry)
				end
			end),
		} :: Entry

		return entry
	end

	local function invoke(
		id: string,
		entry: Entry,
		callback: (...any) -> ...any,
		event: Types.RecognizerEvent?,
		occurrence: number?,
		token: Types.RecognitionToken?
	): ()
		options.Changed()
		entry.live = true
		entry.violation = nil
		entry.cancelling = event ~= nil and event.kind == "Cancelled"

		local success: boolean, failure: string?, raw: any = Observers.Run(callback, entry.context, event)
		entry.live = false

		if not success then
			fault(
				id,
				entry,
				if failure == "Yielded" then "InputRecognizerYielded" else failure or "InputRecognizerFailed"
			)

			return
		end

		local violation: string? = entry.violation

		if violation ~= nil then
			fault(id, entry, violation)

			return
		end

		local match: Types.CustomMatch?, reason: string? = ScalarState.Match(raw)

		if reason ~= nil then
			fault(id, entry, reason)

			return
		end

		if
			match ~= nil
			and (event == nil or event.kind ~= "Cancelled")
			and (occurrence == nil or entry.lastOutput ~= occurrence)
		then
			entry.lastOutput = occurrence

			options.Emit(
				id,
				match,
				if token ~= nil then token.causeRootInputOrdinal else entry.cause,
				if token ~= nil then token.ordinal else nil
			)
		end

		if event == nil or event.kind ~= "Cancelled" then
			arm(entry)
		end
	end

	arm = function(entry: Entry): ()
		local horizon: number? = entry.horizon

		if horizon == nil or destroyed or entry.snapshot.faulted then
			return
		end

		entry.timer.Arm(math.min(horizon, entry.deadline or horizon))
	end

	settle = function(id: string, entry: Entry): ()
		local now: number = options.Now()
		local deadline: number? = entry.deadline

		if deadline ~= nil and now > deadline then
			entry.deadline = nil

			local callback: ((Types.RecognizerContext) -> Types.CustomMatch?)? = entry.snapshot.definition.onDeadline

			if callback ~= nil then
				invoke(id, entry, callback, nil, nil, nil)
			end
		end

		if entry.horizon ~= nil and now > entry.horizon then
			retire(id, entry)
		else
			arm(entry)
		end
	end

	owner = {
		Commit = function(
			catalog: Types.RecognitionCatalog?,
			invalidated: { [string]: string },
			changedDependencies: { [string]: boolean }
		): ()
			local desired: { [string]: Types.RecognizerSnapshot } = if catalog ~= nil then catalog.recognizers else {}

			for id: string, entry: Entry in entries do
				local nextSnapshot: Types.RecognizerSnapshot? = desired[id]

				if
					nextSnapshot == nil
					or entry.snapshot.sourceId ~= nextSnapshot.sourceId
					or not Value.Equal(entry.snapshot.definition, nextSnapshot.definition)
				then
					retire(id, entry)
					entries[id] = nil
				else
					if changedDependencies[id] then
						retire(id, entry)
					end

					for _, inputId: string in entry.snapshot.definition.inputs do
						if invalidated[inputId] ~= nil then
							retire(id, entry)
							break
						end
					end
				end
			end

			for id: string, snapshot: Types.RecognizerSnapshot in desired do
				if entries[id] == nil then
					entries[id] = create(id, snapshot)
				end
			end

			index = if catalog ~= nil then catalog.recognizerIndex else {}
		end,
		Before = function(): ()
			for _, id: string in Value.Keys(active) do
				local entry: Entry = active[id]

				if
					(entry.deadline ~= nil and options.Now() > entry.deadline)
					or (entry.horizon ~= nil and options.Now() > entry.horizon)
				then
					settle(id, entry)
				end
			end
		end,
		Accept = function(
			event: Types.RecognizerEvent,
			key: string,
			occurrence: number,
			token: Types.RecognitionToken
		): ()
			for _, id: string in index[key] or {} do
				local entry: Entry = entries[id]

				if entry.snapshot.faulted then
					continue
				end

				if event.kind == "Cancelled" then
					invoke(id, entry, entry.snapshot.definition.onEvent, event, occurrence, token)
					retire(id, entry)
					continue
				end

				if entry.horizon == nil then
					entry.horizon = options.Now() + entry.snapshot.definition.maxWindowSeconds
					active[id] = entry
				end

				entry.cause = token.causeRootInputOrdinal
				invoke(id, entry, entry.snapshot.definition.onEvent, event, occurrence, token)
			end
		end,
		Watches = function(key: string): boolean
			return index[key] ~= nil
		end,
		Reset = function(inputIds: { string }?): ()
			local selected: { [string]: boolean } = {}

			for _, id: string in inputIds or {} do
				selected[id] = true
			end

			for id: string, entry: Entry in entries do
				local affected: boolean = inputIds == nil

				for _, inputId: string in entry.snapshot.definition.inputs do
					affected = affected or selected[inputId] == true
				end

				if affected then
					retire(id, entry)
					entry.lastOutput = nil
				end
			end
		end,
		Get = function(id: string): Types.RecognizerSnapshot?
			local entry: Entry? = entries[id]

			return if entry ~= nil then entry.snapshot else nil
		end,
		Destroy = function(): ()
			destroyed = true

			for id: string, entry: Entry in entries do
				retire(id, entry)
			end

			table.clear(entries)
			table.clear(active)
			index = {}
		end,
	}

	return owner
end

return Custom
