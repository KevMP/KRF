--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.InputConstants)
local Value = require(script.Parent.InputValue)
local Validation = require(script.Parent.InputRecognitionValidation)
export type Match = { id: string, recognizedAt: number, token: Types.RecognitionToken }

type Lineage = { nodes: { number }, startedAt: number, lastAt: number, pending: { Match } }

type ActiveMachine = {
	definition: Types.SequenceMachine,
	lineages: { Lineage },
	cancel: (() -> ())?,
	armedAt: number?,
	revision: number,
}

export type Options = {
	Now: () -> number,
	Schedule: (number, () -> ()) -> () -> (),
	Emit: ({ Match }, boolean) -> (),
	Changed: () -> (),
}

export type Owner = {
	Commit: (Types.RecognitionCatalog?, { [string]: string }) -> (),
	Before: () -> (),
	Accept: ({ Types.RecognitionToken }) -> (),
	Reset: ({ string }?) -> (),
	Block: (string, boolean) -> (),
	Get: (string) -> Types.SequenceSnapshot?,
	Destroy: () -> (),
}

local Sequences = {}

function Sequences.new(options: Options): Owner
	local machines: { [string]: ActiveMachine } = {}
	local index: { [string]: { string } } = {}
	local snapshots: { [string]: Types.SequenceSnapshot } = {}
	local active: { [string]: ActiveMachine } = {}
	local blocked: { [string]: boolean } = {}
	local destroyed: boolean = false
	local arm: (ActiveMachine) -> ()

	local function clear(machine: ActiveMachine): ()
		machine.armedAt = nil
		machine.revision += 1

		if machine.cancel ~= nil then
			machine.cancel()
			machine.cancel = nil
		end

		table.clear(machine.lineages)
		active[machine.definition.id] = nil
	end

	local function expire(machine: ActiveMachine): ()
		local remaining: { Lineage } = {}
		local emitted: { Match } = {}

		for _, lineage: Lineage in machine.lineages do
			if
				options.Now()
				> math.min(
					lineage.startedAt + machine.definition.maxTotalSeconds,
					lineage.lastAt + machine.definition.maxGapSeconds
				)
			then
				for _, match: Match in lineage.pending do
					table.insert(emitted, match)
				end
			else
				table.insert(remaining, lineage)
			end
		end

		if #remaining ~= #machine.lineages then
			options.Changed()
		end

		machine.lineages = remaining

		if #emitted > 0 then
			options.Emit(emitted, false)
		end

		arm(machine)
	end

	arm = function(machine: ActiveMachine): ()
		if #machine.lineages == 0 or destroyed then
			machine.revision += 1

			if machine.cancel ~= nil then
				machine.cancel()
				machine.cancel = nil
			end

			machine.armedAt = nil
			active[machine.definition.id] = nil

			return
		end

		active[machine.definition.id] = machine

		local deadline: number = math.huge

		for _, lineage: Lineage in machine.lineages do
			deadline = math.min(
				deadline,
				lineage.startedAt + machine.definition.maxTotalSeconds,
				lineage.lastAt + machine.definition.maxGapSeconds
			)
		end

		if machine.armedAt == deadline and machine.cancel ~= nil then
			return
		end

		machine.revision += 1

		if machine.cancel ~= nil then
			machine.cancel()
		end

		machine.armedAt = deadline

		local revision: number = machine.revision

		machine.cancel = options.Schedule(Validation.After(deadline), function(): ()
			if destroyed or machines[machine.definition.id] ~= machine or machine.revision ~= revision then
				return
			end

			machine.cancel = nil
			machine.armedAt = nil
			options.Changed()
			expire(machine)
		end)
	end

	-- Every watched occurrence advances a live start by one compiled edge or
	-- retires it. Depth is capped at MAX_SEQUENCE_STEPS, so overlapping starts
	-- and their trie nodes are bounded without retaining a replay history.

	local function advance(
		machine: ActiveMachine,
		lineage: Lineage,
		tokens: { Types.RecognitionToken }
	): (Lineage?, { Match })
		local definition: Types.SequenceMachine = machine.definition
		local children: { number } = {}
		local seen: { [number]: boolean } = {}
		local matchedTokens: { [number]: Types.RecognitionToken } = {}

		for _, nodeIndex: number in lineage.nodes do
			for _, token: Types.RecognitionToken in tokens do
				local child: number? = definition.nodes[nodeIndex].edges[token.key]

				if child ~= nil and not seen[child] then
					seen[child] = true
					table.insert(children, child)
					matchedTokens[child] = token
				end
			end
		end

		if #children == 0 then
			return nil, lineage.pending
		end

		table.sort(children)
		local completed: { Match } = {}
		local continuation: boolean = false

		for _, child: number in children do
			local node: Types.SequenceNode = definition.nodes[child]
			continuation = continuation or next(node.edges) ~= nil

			-- All alternatives in a lineage have consumed the same number of
			-- occurrences. They therefore share this trie depth.
			if #node.completed > 0 then
				for _, id: string in node.completed do
					table.insert(completed, { id = id, recognizedAt = options.Now(), token = matchedTokens[child] })
				end
			end
		end

		lineage.nodes = children
		lineage.lastAt = options.Now()

		if not definition.deferred then
			return if continuation then lineage else nil, completed
		end

		if #completed > 0 then
			lineage.pending = completed
		end

		if not continuation then
			local result: { Match } = lineage.pending

			lineage.pending = {}

			return nil, result
		end

		return lineage, {}
	end

	return {
		Commit = function(catalog: Types.RecognitionCatalog?, invalidated: { [string]: string }): ()
			local desired: { [string]: Types.SequenceMachine } = if catalog ~= nil then catalog.machines else {}

			for id in blocked do
				if catalog == nil or catalog.recognizers[id] == nil then
					blocked[id] = nil
				end
			end

			for id: string, machine: ActiveMachine in machines do
				local changed: boolean = not Value.Equal(machine.definition, desired[id])

				for inputId in machine.definition.inputs do
					changed = changed or invalidated[inputId] ~= nil
				end

				if changed then
					clear(machine)
					machines[id] = nil
				end
			end

			for id: string, definition: Types.SequenceMachine in desired do
				if machines[id] == nil then
					machines[id] = { definition = definition, lineages = {}, revision = 0 }
				end
			end

			index = if catalog ~= nil then catalog.machineIndex else {}
			snapshots = if catalog ~= nil then catalog.sequences else {}
		end,
		Before = function(): ()
			for _, id: string in Value.Keys(active) do
				local machine: ActiveMachine = active[id]

				for _, lineage: Lineage in machine.lineages do
					if
						options.Now()
						> math.min(
							lineage.startedAt + machine.definition.maxTotalSeconds,
							lineage.lastAt + machine.definition.maxGapSeconds
						)
					then
						expire(machine)
						break
					end
				end
			end
		end,
		Accept = function(tokens: { Types.RecognitionToken }): ()
			local selected: { [string]: boolean } = {}

			for _, token: Types.RecognitionToken in tokens do
				for _, id: string in index[token.key] or {} do
					selected[id] = true
				end
			end

			local immediate: { Match } = {}
			local deferred: { Match } = {}

			for _, id: string in Value.Keys(selected) do
				local machine: ActiveMachine = machines[id]
				local disabled: boolean = false

				for recognizerId in machine.definition.recognizers do
					disabled = disabled or blocked[recognizerId] == true
				end

				if disabled then
					continue
				end

				local remaining: { Lineage } = {}

				for _, lineage: Lineage in machine.lineages do
					local progressed: Lineage?, matches: { Match } = advance(machine, lineage, tokens)

					if progressed ~= nil then
						table.insert(remaining, progressed)
					end

					for _, match: Match in matches do
						-- A pending prefix terminated by a different watched token
						-- must be delivered in a preceding, independent occurrence.
						local fromCurrent: boolean = false

						for _, token: Types.RecognitionToken in tokens do
							fromCurrent = fromCurrent or token.ordinal == match.token.ordinal
						end

						local target: { Match } = if fromCurrent then immediate else deferred
						table.insert(target, match)
					end
				end

				local initial: Lineage =
					{ nodes = { 1 }, startedAt = options.Now(), lastAt = options.Now(), pending = {} }

				local started: Lineage?, matches: { Match } = advance(machine, initial, tokens)

				if started ~= nil then
					table.insert(remaining, started)
				end

				for _, match: Match in matches do
					table.insert(immediate, match)
				end

				assert(#remaining <= Constants.MAX_SEQUENCE_STEPS, "InputSequenceLineageLimitExceeded")
				machine.lineages = remaining
				arm(machine)
			end

			if #deferred > 0 then
				options.Emit(deferred, false)
			end

			if #immediate > 0 then
				options.Emit(immediate, true)
			end

			if next(selected) ~= nil then
				options.Changed()
			end
		end,
		Reset = function(inputIds: { string }?): ()
			local selected: { [string]: boolean } = {}

			for _, inputId: string in inputIds or {} do
				selected[inputId] = true
			end

			for _, machine: ActiveMachine in machines do
				local affected: boolean = inputIds == nil

				for inputId in machine.definition.inputs do
					affected = affected or selected[inputId] == true
				end

				if affected then
					clear(machine)
				end
			end
		end,
		Block = function(recognizerId: string, value: boolean): ()
			blocked[recognizerId] = if value then true else nil

			if value then
				for _, machine: ActiveMachine in machines do
					if machine.definition.recognizers[recognizerId] then
						clear(machine)
					end
				end
			end
		end,
		Get = function(id: string): Types.SequenceSnapshot?
			return snapshots[id]
		end,
		Destroy = function(): ()
			destroyed = true

			for _, machine: ActiveMachine in machines do
				clear(machine)
			end

			table.clear(machines)
			table.clear(active)
			table.clear(blocked)
			index = {}
			snapshots = {}
		end,
	}
end

return Sequences
