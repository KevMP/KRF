--!strict
local Types = require(script.Parent.Parent.types)
local Validator = require(script.Parent.Parent.InputValidator)
local Store = require(script.Parent.InputPreparedStore)
local RecognitionPlans = require(script.Parent.InputRecognitionPlans)
local Value = require(script.Parent.InputValue)
local Changes = require(script.Parent.InputGraphChanges)
local Configuration = require(script.Parent.InputConfiguration)
local MutationGate = require(script.Parent.InputMutationGate)
local RecognitionPipeline = require(script.Parent.InputRecognitionPipeline)

export type GraphAccess = {
	Current: () -> Types.InputGraphSnapshot,
	CompileSource: (sourceId: string, definition: Types.InputSourceDefinition?) -> (Types.InputGraphSnapshot?, string?),
	Validate: (graph: Types.InputGraphSnapshot, profiles: unknown) -> string?,
	Version: () -> number,
	Commit: (
		graph: Types.InputGraphSnapshot,
		reason: string?,
		publishSelection: (() -> ())?,
		invalidated: { [string]: string }?
	) -> (boolean, string?, Types.InputCommitFailurePhase?),
	SelectionFence: () -> Configuration.SelectionFence?,
}

export type Owner = {
	PrepareGraph: (Types.InputGraphSnapshot, unknown) -> (Types.PreparedInputUpdate?, string?),
	CommitControlUpdate: (
		Types.PreparedInputUpdate,
		Types.PreparedInputInvalidation?,
		() -> ()
	) -> (boolean, string?, Types.InputCommitFailurePhase?),
	Validate: (plan: { read token: unknown, read generation: number }) -> (boolean, string?),
	Release: (plan: { read token: unknown, read generation: number }) -> (),
	ResetRecognition: (inputIds: { string }?, reason: string) -> (boolean, string?),
	PrepareRecognitionReset: (inputIds: { string }?, reason: string) -> (Types.PreparedRecognitionReset?, string?),
	CommitPreparedRecognitionReset: (plan: Types.PreparedRecognitionReset) -> (boolean, string?),
	PrepareSource: (
		sourceId: string,
		definition: Types.InputSourceDefinition?,
		profiles: unknown
	) -> (Types.PreparedInputUpdate?, string?),
	CommitPrepared: (plan: Types.PreparedInputUpdate) -> (boolean, string?),
	CommitPreparedWithPublication: (plan: Types.PreparedInputUpdate, publishSelection: () -> ()) -> (boolean, string?),
	PrepareEpochInvalidation: (
		reason: string,
		inputIds: { string }?,
		skipValidation: boolean?
	) -> (Types.PreparedInputInvalidation?, string?),
	CommitEpochInvalidation: (
		plan: Types.PreparedInputInvalidation,
		publishSelection: () -> ()
	) -> (boolean, string?, Types.InputCommitFailurePhase?),
	Clear: () -> (),
}

type PreparedRecord = Store.Record

local Plans = {}

-- Owns bounded, generation-qualified capabilities, not the installed graph.
function Plans.new(access: GraphAccess, gate: MutationGate.Owner, recognition: RecognitionPipeline.Owner): Owner
	local prepared: Store.Store = Store.new()
	local resets: RecognitionPlans.Owner = RecognitionPlans.new(access, gate, recognition, prepared)

	local function prepare(record: PreparedRecord): (Types.InputPlan?, string?)
		return prepared.Put(record)
	end

	local function PrepareSource(
		sourceId: string,
		definition: Types.InputSourceDefinition?,
		profiles: unknown
	): (Types.PreparedInputUpdate?, string?)
		local reason: string? = gate.Unavailable()

		if reason ~= nil then
			return nil, reason
		end

		if gate.IsBusy() then
			return nil, "InputMutationReentrant"
		end

		if type(sourceId) ~= "string" or #sourceId == 0 then
			return nil, "InvalidSourceId"
		end

		local normalized: Types.InputSourceDefinition? = nil

		if definition ~= nil then
			normalized, reason = Validator.Normalize(sourceId, definition)

			if normalized == nil then
				return nil, reason
			end
		end

		local desired: Types.InputGraphSnapshot?
		desired, reason = access.CompileSource(sourceId, normalized)

		if desired == nil then
			return nil, reason
		end

		reason = access.Validate(desired, profiles)

		if reason ~= nil then
			return nil, reason
		end

		return prepare({
			generation = access.Current().generation,
			validators = access.Version(),
			kind = "Source",
			graph = desired,
			profiles = profiles,
			consumed = false,
		})
	end

	local function PrepareGraph(
		graph: Types.InputGraphSnapshot,
		profiles: unknown
	): (Types.PreparedInputUpdate?, string?)
		local unavailable: string? = gate.Unavailable()

		if unavailable ~= nil then
			return nil, unavailable
		end

		if gate.IsBusy() then
			return nil, "InputMutationReentrant"
		end

		local rejection: string? = access.Validate(graph, profiles)

		if rejection ~= nil then
			return nil, rejection
		end

		return prepare({
			generation = access.Current().generation,
			validators = access.Version(),
			kind = "Source",
			graph = graph,
			profiles = profiles,
			consumed = false,
		})
	end

	local function PrepareEpochInvalidation(
		reason: string,
		inputIds: { string }?,
		skipValidation: boolean?
	): (Types.PreparedInputInvalidation?, string?)
		local unavailableReason: string? = gate.Unavailable()

		if unavailableReason ~= nil then
			return nil, unavailableReason
		end

		if gate.IsBusy() then
			return nil, "InputMutationReentrant"
		end

		if type(reason) ~= "string" or #reason == 0 then
			return nil, "InvalidInputInvalidationReason"
		end

		local rejected: string? = if skipValidation then nil else access.Validate(access.Current(), nil)

		if rejected ~= nil then
			return nil, rejected
		end

		return prepare({
			generation = access.Current().generation,
			validators = access.Version(),
			kind = "Epoch",
			skipValidation = skipValidation,
			reason = reason,
			inputIds = inputIds,
			consumed = false,
		})
	end

	local function take(plan: unknown, kind: string): (PreparedRecord?, string?)
		local reason: string? = gate.Unavailable()

		if reason ~= nil then
			return nil, reason
		end

		if gate.IsBusy() then
			return nil, "InputMutationReentrant"
		end

		local record: PreparedRecord? = prepared.Read(plan)

		if record == nil or record.kind ~= kind then
			return nil, "InvalidInputPlan"
		end

		if
			record.consumed
			or record.generation ~= access.Current().generation
			or record.validators ~= access.Version()
		then
			return nil, "StaleInputPlan"
		end

		record.consumed = true

		return record, nil
	end

	local function CommitPrepared(plan: Types.PreparedInputUpdate, publishSelection: (() -> ())?): (boolean, string?)
		local record: PreparedRecord?, reason: string? = take(plan, "Source")

		if record == nil then
			return false, reason
		end

		assert(record.graph ~= nil, "Expected prepared input graph")
		reason = access.Validate(record.graph, record.profiles)

		if reason ~= nil then
			return false, reason
		end

		local accepted: boolean, failure: string? = access.Commit(record.graph, nil, publishSelection)

		return accepted, failure
	end

	local function CommitControlUpdate(
		plan: Types.PreparedInputUpdate,
		epoch: Types.PreparedInputInvalidation?,
		publish: () -> ()
	): (boolean, string?, Types.InputCommitFailurePhase?)
		local record: PreparedRecord?, reason: string? = take(plan, "Source")

		if record == nil then
			return false, reason :: string?, "Rejected"
		end

		local invalidated: { [string]: string }? = nil

		if epoch ~= nil then
			local retirement: PreparedRecord?
			retirement, reason = take(epoch, "Epoch")

			if retirement == nil then
				return false, reason :: string?, "Rejected"
			end

			invalidated = {}

			for _, inputId in retirement.inputIds or Value.Keys(access.Current().inputs) do
				invalidated[inputId] = retirement.reason or "InputInvalidated"
			end
		end

		local graph: Types.InputGraphSnapshot = assert(record.graph, "Expected prepared graph")
		reason = access.Validate(graph, record.profiles)

		if reason ~= nil then
			return false, reason :: string?, "Rejected"
		end

		return access.Commit(graph, nil, publish, invalidated)
	end

	local function CommitEpochInvalidation(
		plan: Types.PreparedInputInvalidation,
		publishSelection: () -> ()
	): (boolean, string?, Types.InputCommitFailurePhase?)
		local record: PreparedRecord?, reason: string? = take(plan, "Epoch")

		if record == nil then
			return false, reason :: string?, "Rejected"
		end

		reason = if record.skipValidation then nil else access.Validate(access.Current(), nil)

		if reason ~= nil then
			return false, reason :: string?, "Rejected"
		end

		local desired: Types.InputGraphSnapshot = Changes.Next(access.Current(), nil)

		local forced: { [string]: string }? = nil

		if record.inputIds ~= nil then
			forced = {}

			for _, inputId in record.inputIds do
				forced[inputId] = record.reason or "InputInvalidated"
			end
		end

		local committed: boolean, failure: string? =
			access.Commit(desired, if forced == nil then record.reason else nil, publishSelection, forced)

		return committed, failure, if committed then nil else "Failed"
	end

	return {
		Validate = function(plan: { read token: unknown, read generation: number }): (boolean, string?)
			local record: PreparedRecord? = prepared.Read(plan)

			if record == nil then
				return false, "InvalidInputPlan"
			end

			if
				record.consumed
				or record.generation ~= access.Current().generation
				or record.validators ~= access.Version()
				or (record.recognitionRevision ~= nil and record.recognitionRevision ~= recognition.Revision())
			then
				return false, "StaleInputPlan"
			end

			return true, nil
		end,
		Release = function(plan: { read token: unknown, read generation: number }): ()
			prepared.Release(plan)
		end,
		ResetRecognition = resets.Reset,
		PrepareRecognitionReset = resets.Prepare,
		CommitPreparedRecognitionReset = resets.Commit,
		PrepareSource = PrepareSource,
		PrepareGraph = PrepareGraph,
		CommitControlUpdate = CommitControlUpdate,
		CommitPrepared = function(plan: Types.PreparedInputUpdate): (boolean, string?)
			return CommitPrepared(plan, nil)
		end,
		CommitPreparedWithPublication = CommitPrepared,
		PrepareEpochInvalidation = PrepareEpochInvalidation,
		CommitEpochInvalidation = CommitEpochInvalidation,
		Clear = function(): ()
			prepared.Clear()
		end,
	}
end

return Plans
