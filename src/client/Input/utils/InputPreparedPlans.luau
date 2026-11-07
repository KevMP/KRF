--!strict
local Types = require(script.Parent.Parent.types)
local Validator = require(script.Parent.Parent.InputValidator)
local Constants = require(script.Parent.InputConstants)
local Value = require(script.Parent.InputValue)
local Changes = require(script.Parent.InputGraphChanges)
local Configuration = require(script.Parent.InputConfiguration)
local MutationGate = require(script.Parent.InputMutationGate)
local RecognitionPipeline = require(script.Parent.InputRecognitionPipeline)

export type GraphAccess = {
	Current: () -> Types.InputGraphSnapshot,
	CompileSource: (sourceId: string, definition: Types.InputSourceDefinition?) -> (Types.InputGraphSnapshot?, string?),
	Validate: (graph: Types.InputGraphSnapshot, profiles: any?) -> string?,
	Version: () -> number,
	Commit: (graph: Types.InputGraphSnapshot, reason: string?, publishSelection: (() -> ())?) -> (boolean, string?),
	SelectionFence: () -> Configuration.SelectionFence?,
}

export type Owner = {
	Validate: (plan: { read token: unknown, read generation: number }) -> (boolean, string?),
	Release: (plan: { read token: unknown, read generation: number }) -> (),
	ResetRecognition: (inputIds: { string }?, reason: string) -> (boolean, string?),
	PrepareRecognitionReset: (inputIds: { string }?, reason: string) -> (Types.PreparedRecognitionReset?, string?),
	CommitPreparedRecognitionReset: (plan: Types.PreparedRecognitionReset) -> (boolean, string?),
	PrepareSource: (
		sourceId: string,
		definition: Types.InputSourceDefinition?,
		profiles: any?
	) -> (Types.PreparedInputUpdate?, string?),
	CommitPrepared: (plan: Types.PreparedInputUpdate) -> (boolean, string?),
	CommitPreparedWithPublication: (plan: Types.PreparedInputUpdate, publishSelection: () -> ()) -> (boolean, string?),
	PrepareEpochInvalidation: (reason: string) -> (Types.PreparedInputInvalidation?, string?),
	CommitEpochInvalidation: (
		plan: Types.PreparedInputInvalidation,
		publishSelection: () -> ()
	) -> (boolean, string?, Types.InputCommitFailurePhase?),
	Clear: () -> (),
}

type PreparedRecord = {
	generation: number,
	validators: number,
	kind: string,
	graph: Types.InputGraphSnapshot?,
	profiles: any?,
	reason: string?,
	consumed: boolean,
	inputIds: { string }?,
	recognitionRevision: number?,
}

local Plans = {}

-- Owns bounded, generation-qualified capabilities, not the installed graph.
function Plans.new(access: GraphAccess, gate: MutationGate.Owner, recognition: RecognitionPipeline.Owner): Owner
	local prepared: { [any]: PreparedRecord } = setmetatable({}, { __mode = "k" })

	local function resetSelection(inputIds: { string }?, reason: string): ({ string }?, string?)
		if type(reason) ~= "string" or #reason == 0 then
			return nil, "InvalidRecognitionResetReason"
		end

		if inputIds == nil then
			return Value.Keys(access.Current().inputs), nil
		end

		if type(inputIds) ~= "table" or getmetatable(inputIds) ~= nil then
			return nil, "InvalidRecognitionResetInputs"
		end

		local selected: { string } = {}
		local seen: { [string]: boolean } = {}

		for index, inputId in inputIds do
			if
				type(index) ~= "number"
				or index % 1 ~= 0
				or index < 1
				or index > #inputIds
				or type(inputId) ~= "string"
				or seen[inputId]
			then
				return nil, "InvalidRecognitionResetInputs"
			end

			if access.Current().inputs[inputId] == nil then
				return nil, "UnknownInput"
			end

			seen[inputId] = true
			table.insert(selected, inputId)
		end

		if #selected ~= #inputIds then
			return nil, "InvalidRecognitionResetInputs"
		end

		return selected, nil
	end

	local function ResetRecognition(inputIds: { string }?, reason: string): (boolean, string?)
		local rejection: string? = gate.Unavailable()

		if rejection ~= nil then
			return false, rejection
		end

		if gate.IsBusy() then
			return false, "InputMutationReentrant"
		end

		local selected: { string }?, failure: string? = resetSelection(inputIds, reason)

		if selected == nil then
			return false, failure
		end

		gate.SetFenced(true)
		recognition.Reset(selected)
		gate.SetFenced(false)
		gate.Flush()

		return true, nil
	end

	local function prepare(record: PreparedRecord): (any, string?)
		local total: number = 0

		for _ in prepared do
			total += 1
		end

		if total >= Constants.MAX_PREPARED_PLANS then
			return nil, "InputPlanLimitExceeded"
		end

		local plan = table.freeze({ generation = access.Current().generation, token = table.freeze({}) })

		prepared[plan] = record

		return plan, nil
	end

	local function PrepareRecognitionReset(
		inputIds: { string }?,
		reason: string
	): (Types.PreparedRecognitionReset?, string?)
		local rejection: string? = gate.Unavailable()

		if rejection ~= nil then
			return nil, rejection
		end

		if gate.IsBusy() then
			return nil, "InputMutationReentrant"
		end

		local selected: { string }?, failure: string? = resetSelection(inputIds, reason)

		if selected == nil then
			return nil, failure
		end

		return prepare({
			generation = access.Current().generation,
			validators = access.Version(),
			kind = "Recognition",
			inputIds = selected,
			recognitionRevision = recognition.Revision(),
			consumed = false,
		})
	end

	local function CommitPreparedRecognitionReset(plan: Types.PreparedRecognitionReset): (boolean, string?)
		local rejection: string? = gate.Unavailable()

		if rejection ~= nil then
			return false, rejection
		end

		local fence: Configuration.SelectionFence? = access.SelectionFence()

		if not gate.IsFenced() or fence == nil then
			return false, "InputCommitFenceRequired"
		end

		local record: PreparedRecord? = prepared[plan]

		if record == nil or record.kind ~= "Recognition" then
			return false, "InvalidRecognitionReset"
		end

		if
			record.consumed
			or record.generation ~= fence.generation
			or record.recognitionRevision ~= fence.recognitionRevision
			or record.validators ~= access.Version()
		then
			return false, "StaleRecognitionReset"
		end

		record.consumed = true
		recognition.Reset(record.inputIds)

		return true, nil
	end

	local function PrepareSource(
		sourceId: string,
		definition: Types.InputSourceDefinition?,
		profiles: any?
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

	local function PrepareEpochInvalidation(reason: string): (Types.PreparedInputInvalidation?, string?)
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

		local rejected: string? = access.Validate(access.Current(), nil)

		if rejected ~= nil then
			return nil, rejected
		end

		return prepare({
			generation = access.Current().generation,
			validators = access.Version(),
			kind = "Epoch",
			reason = reason,
			consumed = false,
		})
	end

	local function take(plan: any, kind: string): (PreparedRecord?, string?)
		local reason: string? = gate.Unavailable()

		if reason ~= nil then
			return nil, reason
		end

		if gate.IsBusy() then
			return nil, "InputMutationReentrant"
		end

		local record: PreparedRecord? = prepared[plan]

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

		return access.Commit(record.graph, nil, publishSelection)
	end

	local function CommitEpochInvalidation(
		plan: Types.PreparedInputInvalidation,
		publishSelection: () -> ()
	): (boolean, string?, Types.InputCommitFailurePhase?)
		local record: PreparedRecord?, reason: string? = take(plan, "Epoch")

		if record == nil then
			return false, reason, "Rejected"
		end

		reason = access.Validate(access.Current(), nil)

		if reason ~= nil then
			return false, reason, "Rejected"
		end

		local desired: Types.InputGraphSnapshot = Changes.Next(access.Current(), nil)

		local committed: boolean, failure: string? = access.Commit(desired, record.reason, publishSelection)

		return committed, failure, if committed then nil else "Failed"
	end

	return {
		Validate = function(plan: { read token: unknown, read generation: number }): (boolean, string?)
			local record: PreparedRecord? = prepared[plan]

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
			prepared[plan] = nil
		end,
		ResetRecognition = ResetRecognition,
		PrepareRecognitionReset = PrepareRecognitionReset,
		CommitPreparedRecognitionReset = CommitPreparedRecognitionReset,
		PrepareSource = PrepareSource,
		CommitPrepared = function(plan: Types.PreparedInputUpdate): (boolean, string?)
			return CommitPrepared(plan, nil)
		end,
		CommitPreparedWithPublication = CommitPrepared,
		PrepareEpochInvalidation = PrepareEpochInvalidation,
		CommitEpochInvalidation = CommitEpochInvalidation,
		Clear = function(): ()
			table.clear(prepared)
		end,
	}
end

return Plans
