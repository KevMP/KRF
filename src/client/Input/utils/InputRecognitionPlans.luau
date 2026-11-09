--!strict
local Types = require(script.Parent.Parent.types)
local Value = require(script.Parent.InputValue)
local Configuration = require(script.Parent.InputConfiguration)
local MutationGate = require(script.Parent.InputMutationGate)
local RecognitionPipeline = require(script.Parent.InputRecognitionPipeline)
local Store = require(script.Parent.InputPreparedStore)

export type Access = {
	Current: () -> Types.InputGraphSnapshot,
	Version: () -> number,
	SelectionFence: () -> Configuration.SelectionFence?,
}

export type Owner = {
	Reset: ({ string }?, string) -> (boolean, string?),
	Prepare: ({ string }?, string) -> (Types.PreparedRecognitionReset?, string?),
	Commit: (Types.PreparedRecognitionReset) -> (boolean, string?),
}

local Plans = {}

function Plans.new(
	access: Access,
	gate: MutationGate.Owner,
	recognition: RecognitionPipeline.Owner,
	prepared: Store.Store
): Owner
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

		return prepared.Put({
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

		local record: Store.Record? = prepared.Read(plan)

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

	return { Reset = ResetRecognition, Prepare = PrepareRecognitionReset, Commit = CommitPreparedRecognitionReset }
end

return Plans
