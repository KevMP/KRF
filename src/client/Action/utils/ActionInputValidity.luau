--!strict
local Types = require(script.Parent.Parent.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local Graph = require(script.Parent.ActionProfileGraph)
local Transitions = require(script.Parent.ActionRouteTransitions)

export type Access = {
	Catalog: () -> Graph.Catalog,
	Prepared: (unknown) -> Graph.Catalog?,
	IsDestroyed: () -> boolean,
	IsSwitching: () -> boolean,
	Publish: ({ Types.EffectiveRouteTransition }) -> (),
	Fail: ({ Types.EffectiveRouteTransition }, string) -> (),
}

export type Owner = { MarkPublished: (number) -> (), Destroy: () -> () }

local Validity = {}

-- One validator and one synchronous commit observer share the same published
-- input-generation cursor. The Action owner alone installs or clears its state.
function Validity.new(input: InputTypes.InputOwner, access: Access): Owner
	local published: number? = nil
	local disconnects: { () -> () } = {}

	local function destroy(): ()
		published = nil

		for _, disconnect in disconnects do
			disconnect()
		end

		table.clear(disconnects)
	end

	local installed: boolean, reason: unknown = pcall(function(): ()
		table.insert(
			disconnects,
			input.RegisterGraphValidator(
				function(graph: InputTypes.InputGraphSnapshot, proposed: unknown): (boolean, string?)
					local desired: Graph.Catalog = access.Catalog()

					if proposed ~= nil then
						local prepared: Graph.Catalog? = access.Prepared(proposed)

						if prepared == nil then
							return false, "InvalidProfileGraph"
						end

						desired = prepared
					end

					local valid: boolean = Graph.Validate(desired, graph)

					return valid, if valid then nil else "ProfileDependencyMissing"
				end
			)
		)

		table.insert(
			disconnects,
			input.ObserveConfigurationCommit(function(change: InputTypes.InputGraphChange): ()
				if access.IsDestroyed() or access.IsSwitching() then
					return
				end

				local catalog: Graph.Catalog = access.Catalog()

				if input.GetMutationStatus() == "InputRuntimeFaulted" or not Graph.Validate(catalog, change.next) then
					access.Fail(
						Transitions.DiffCatalogs(catalog, {}, change.previous, change.next, "InputInvalidated"),
						if table.find(change.reasons, "InputRuntimeFaulted") ~= nil
							then "InputRuntimeFaulted"
							else "ProfilePublicationMissing"
					)

					return
				end

				local alreadyPublished: boolean = published == change.next.generation
				published = nil

				if alreadyPublished then
					return
				end

				local invalidated: { [string]: boolean } = {}

				for _, inputId in change.affectedInputIds do
					invalidated[inputId] = true
				end

				access.Publish(
					Transitions.DiffCatalogs(
						catalog,
						catalog,
						change.previous,
						change.next,
						if #change.reasons > 0 then table.concat(change.reasons, ",") else "RecognitionChanged",
						invalidated
					)
				)
			end)
		)
	end)

	if not installed then
		destroy()
		error(reason, 0)
	end

	return {
		MarkPublished = function(generation: number): ()
			published = generation
		end,
		Destroy = destroy,
	}
end

return Validity
