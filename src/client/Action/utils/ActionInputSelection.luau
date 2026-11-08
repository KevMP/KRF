--!strict
local Types = require(script.Parent.Parent.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local RequestTypes = require(script.Parent.Parent.Parent.ActionRequest.types)
local Registry = require(script.Parent.Parent.Parent.Actor.utils.ActorViewRegistryState)
local Activations = require(script.Parent.ActionInputActivations)
local Parameters = require(script.Parent.ActionInputParameters)

export type Options = {
	Policies: Types.ActionInputCatalog,
	CanDispatch: () -> boolean,
	GetRoutes: () -> Types.ActionInputRoutePort?,
	IsPressEpochActive: (string, number, number) -> boolean,
	Start: (RequestTypes.ActionStartSelection, any?) -> (number?, string?),
	Retire: (number) -> (),
	Store: {
		Add: (Types.ActionRouteSelection, Types.CompiledActionInputPolicy) -> Activations.Record?,
		Bind: (Activations.Record, RequestTypes.ActionRequestAdmission) -> (),
		Remove: (Activations.Record) -> (),
		FindToggle: (Types.ActionRouteSelection) -> Activations.Record?,
	},
	ToggleOff: (Activations.Record) -> (),
	Flush: (Activations.Record) -> (),
	Report: (string) -> (),
}

local Selection = {}

function Selection.new(options: Options): (Types.ActionRouteSelection, any?) -> ()
	local store = options.Store
	local report = options.Report

	local function eligible(selection: Types.ActionRouteSelection, policy: Types.CompiledActionInputPolicy): boolean
		local port: Types.ActionInputRoutePort? = options.GetRoutes()

		if port == nil or port.GetControlledActor() ~= selection.actor or Registry.IsInvalidating(selection.actor) then
			return false
		end

		local current: Types.RouteQuerySnapshot? = port.GetEffectiveRoute(selection.actor, selection.key)

		if
			current == nil
			or current.status ~= "Mapped"
			or current.sourceId ~= selection.sourceId
			or current.version ~= selection.routeVersion
		then
			return false
		end

		local hold: InputTypes.RecognitionHoldOwner? = selection.holdOwner

		return policy.activation ~= "WhileDown"
			or (hold ~= nil and options.IsPressEpochActive(hold.inputId, hold.pressEpochId, hold.inputGeneration))
	end

	return function(selection: Types.ActionRouteSelection, resolved: any?): ()
		local policy: Types.CompiledActionInputPolicy? = options.Policies[selection.actionId]

		if not options.CanDispatch() then
			return
		elseif policy == nil then
			report("ActionRequestUnregistered")

			return
		elseif not eligible(selection, policy) then
			report("ActionInputOccurrenceIneligible")

			return
		end

		local toggled: Activations.Record? = if policy.activation == "Toggle" then store.FindToggle(selection) else nil

		if toggled ~= nil then
			options.ToggleOff(toggled)

			return
		end

		local context: Types.ActionInputContext = table.freeze({
			actor = selection.actor,
			actionId = selection.actionId,
			routeKey = selection.key,
			resolvedParameters = resolved,
			input = selection.holdOwner,
		})

		local produced: boolean, parameters: any, reason: string? =
			Parameters.Produce(policy.startParameters, context, resolved)

		if not produced or not eligible(selection, policy) then
			report(reason or "ActionInputOccurrenceIneligible")

			return
		end

		local record: Activations.Record? = if policy.activation ~= "OneShot" then store.Add(selection, policy) else nil

		if policy.activation ~= "OneShot" and record == nil then
			report("ActionInputCapacityReached")

			return
		end

		local requestId: number?, failure: string? = options.Start({
			actor = selection.actor,
			actionId = selection.actionId,
			origin = "Input",
			inputTimestamp = selection.envelope.timestamp,
			Reserve = if record ~= nil
				then function(admission): ()
					store.Bind(record :: Activations.Record, admission)
				end
				else nil,
		}, parameters)

		if record ~= nil then
			record.starting = false

			if requestId == nil then
				store.Remove(record)
			else
				options.Flush(record)
			end
		elseif requestId ~= nil then
			options.Retire(requestId)
		end

		if failure ~= nil then
			report(failure)
		end
	end
end

return Selection
