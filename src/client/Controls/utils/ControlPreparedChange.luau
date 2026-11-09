--!strict
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local ActionTypes = require(script.Parent.Parent.Parent.Action.types)
local Validator = require(script.Parent.Parent.ControlValidator)

export type Plan = {
	input: InputTypes.PreparedInputUpdate,
	profiles: ActionTypes.PreparedProfileGraph,
	selection: ActionTypes.PreparedActorSwitch,
}

local Prepared = {}

function Prepared.Release(input: InputTypes.InputOwner, actions: ActionTypes.ClientActionOwner, plan: Plan): ()
	input.ReleasePrepared(plan.input)
	actions.ReleasePreparedProfiles(plan.profiles)
	actions.ReleaseControlledActor(plan.selection)
end

function Prepared.Compile(
	input: InputTypes.InputOwner,
	actions: ActionTypes.ClientActionOwner,
	change: Validator.Normalized
): (Plan?, string?)
	local graph: InputTypes.InputGraphSnapshot?, reason: string? = input.CompileUpdate(change.inputs, change.contexts)

	if graph == nil then
		return nil, reason
	end

	local profiles: ActionTypes.PreparedProfileGraph?
	profiles, reason = actions.PrepareProfiles(change.profiles, graph)

	if profiles == nil then
		return nil, reason
	end

	local configuration: InputTypes.PreparedInputUpdate?
	configuration, reason = input.PrepareGraph(graph, profiles)

	if configuration == nil then
		actions.ReleasePreparedProfiles(profiles)

		return nil, reason
	end

	local selection: ActionTypes.PreparedActorSwitch?

	selection, reason = actions.PrepareControlledActor(
		if change.selection ~= nil then change.selection.actor else actions.GetControlledActor(),
		true
	)

	if selection == nil then
		input.ReleasePrepared(configuration)
		actions.ReleasePreparedProfiles(profiles)

		return nil, reason
	end

	return { input = configuration, profiles = profiles, selection = selection }, nil
end

return Prepared
