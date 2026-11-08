--!strict
local Types = require(script.Parent.types)
local MutationGate = require(script.Parent.utils.InputMutationGate)
local Dispatch = require(script.Parent.utils.InputDispatch)
local GraphObservers = require(script.Parent.utils.InputGraphObservers)
local Configuration = require(script.Parent.utils.InputConfiguration)
local PreparedPlans = require(script.Parent.utils.InputPreparedPlans)

local InputOwner = {}

function InputOwner.new(options: Types.InputOwnerOptions): Types.InputOwner
	local function report(reason: string): ()
		pcall(options.ReportFault, reason)
	end

	local configuration: Configuration.Owner
	local plans: PreparedPlans.Owner
	local gate: MutationGate.Owner = MutationGate.new(options.IsReady, report)
	local observers: GraphObservers.Owner = GraphObservers.new(gate)

	local dispatch: Dispatch.Owner = Dispatch.new(
		{
			Now = options.Now,
			Publish = options.Publish,
			PublishGesture = options.PublishGesture,
			PublishSequence = options.PublishSequence,
			PublishRecognizer = options.PublishRecognizer,
			IsEpochActive = function(inputId: string, epochId: number, generation: number): boolean
				return configuration.IsPressEpochActive(inputId, epochId, generation)
			end,
			Scheduler = options.Scheduler,
			ReportFault = report,
		},
		gate,
		function(): ()
			configuration.Fail(nil)
		end
	)

	configuration = Configuration.new({
		Native = options.Native,
		ReportFault = report,
		ClearPlans = function(): ()
			plans.Clear()
		end,
	}, gate, dispatch, observers)

	plans = PreparedPlans.new({
		Current = configuration.Graph,
		CompileSource = configuration.CompileSource,
		Validate = observers.Validate,
		Version = observers.Version,
		Commit = configuration.Commit,
		SelectionFence = configuration.SelectionFence,
	}, gate, dispatch.Recognition)

	return {
		AfterCommit = function(callback: () -> ()): (boolean, string?)
			if gate.IsTerminal() then
				return false, "ClientNotReady"
			elseif gate.IsFenced() then
				return gate.Queue(callback)
			end

			callback()

			return true, nil
		end,
		ReleasePrepared = plans.Release,
		ValidatePrepared = plans.Validate,
		GetCommitContext = configuration.SelectionFence,
		GetGraphSnapshot = configuration.Graph,
		GetMutationStatus = function(): string?
			return gate.Unavailable()
				or (
					if gate.IsFenced() or (gate.IsBusy() and not dispatch.IsPublishing())
						then "InputMutationReentrant"
						else nil
				)
		end,
		Disarm = configuration.Disarm,
		GetSequence = dispatch.Recognition.GetSequence,
		GetRecognizer = dispatch.Recognition.GetRecognizer,
		ObserveCandidateEnvelope = dispatch.ObserveEnvelopes,
		SetSource = configuration.SetSource,
		RemoveSource = configuration.RemoveSource,
		SetContextEnabled = configuration.SetContextEnabled,
		GetInput = configuration.GetInput,
		GetContext = configuration.GetContext,
		GetEffectiveBindings = configuration.GetEffectiveBindings,
		BindActionLabel = configuration.BindActionLabel,
		UnbindActionLabel = configuration.UnbindActionLabel,
		IsPressEpochActive = configuration.IsPressEpochActive,
		GetGestures = dispatch.Recognition.Get,
		ObservePrimitive = dispatch.ObservePrimitive,
		ObserveDispatchGroup = dispatch.ObserveGroups,
		RegisterGraphValidator = observers.RegisterValidator,
		ObserveConfigurationCommit = observers.ObserveCommit,
		PrepareSource = plans.PrepareSource,
		CommitPrepared = plans.CommitPrepared,
		CommitPreparedWithPublication = plans.CommitPreparedWithPublication,
		PrepareEpochInvalidation = plans.PrepareEpochInvalidation,
		CommitEpochInvalidation = plans.CommitEpochInvalidation,
		ResetRecognition = plans.ResetRecognition,
		PrepareRecognitionReset = plans.PrepareRecognitionReset,
		CommitPreparedRecognitionReset = plans.CommitPreparedRecognitionReset,
		Destroy = configuration.Destroy,
	}
end

return InputOwner
