--!strict
local Types = require(script.Parent.types)
local ActionRequestTypes = require(script.Parent.Parent.Parent.shared.ActionRequest.types)

type State = {
	catalog: ActionRequestTypes.ActionRequestCatalog,
	options: Types.ClientActionRequestOptions,
	destroyed: boolean,
}

local ClientActionRequestRuntime = {}
ClientActionRequestRuntime.__index = ClientActionRequestRuntime

type Runtime = typeof(setmetatable({} :: State, ClientActionRequestRuntime))

-- I5 TDD scaffold. Typed payload admission, original-Start retention and outcome
-- correlation remain unimplemented; nothing is admitted or sent.
function ClientActionRequestRuntime.Start(
	_self: Runtime,
	_selection: Types.ActionStartSelection,
	_parameters: any?
): (number?, string?)
	return nil, "ActionRequestUnavailable"
end

function ClientActionRequestRuntime.Stop(
	_self: Runtime,
	_originalStartRequestId: number,
	_parameters: any?
): (number?, string?)
	return nil, "ActionRequestUnavailable"
end

function ClientActionRequestRuntime.Interrupt(
	_self: Runtime,
	_originalStartRequestId: number,
	_reason: ActionRequestTypes.ActionInputInterruptReason
): (number?, string?)
	return nil, "ActionRequestUnavailable"
end

function ClientActionRequestRuntime.GetOriginalStart(_self: Runtime, _requestId: number): Types.ActionRequestAdmission?
	return nil
end

function ClientActionRequestRuntime.Retire(_self: Runtime, _originalStartRequestId: number): () end

function ClientActionRequestRuntime.ObserveAdmissions(
	_self: Runtime,
	_observer: (Types.ActionRequestAdmission) -> ()
): () -> ()
	return function(): () end
end

function ClientActionRequestRuntime.ObserveOutcomes(
	_self: Runtime,
	_observer: (Types.ActionRequestOutcome) -> ()
): () -> ()
	return function(): () end
end

function ClientActionRequestRuntime._GetRetainedCountForTests(_self: Runtime): number
	return 0
end

function ClientActionRequestRuntime.Destroy(self: Runtime): ()
	self.destroyed = true
end

local module: Types.ClientActionRequestRuntimeModule = {
	new = function(
		catalog: ActionRequestTypes.ActionRequestCatalog,
		options: Types.ClientActionRequestOptions
	): Types.ClientActionRequestRuntime
		local state: State = { catalog = catalog, options = options, destroyed = false }

		return setmetatable(state, ClientActionRequestRuntime) :: Types.ClientActionRequestRuntime
	end,
}

return table.freeze(module)
