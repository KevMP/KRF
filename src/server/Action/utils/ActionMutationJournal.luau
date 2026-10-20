--!strict
local ActionTypes = require(script.Parent.Parent.types)
local Hooks = require(script.Parent.ActionControllerHooks)

export type MutationFailure = { value: any }

type Observer = { callback: ({ ActionTypes.ActionReplicationMutation }) -> (), active: boolean }

export type ActionMutationJournal = {
	Observe: (self: ActionMutationJournal, callback: ({ ActionTypes.ActionReplicationMutation }) -> ()) -> () -> (),
	Commit: (self: ActionMutationJournal, mutations: { ActionTypes.ActionReplicationMutation }) -> MutationFailure?,
	Destroy: (self: ActionMutationJournal) -> (),
}

local ActionMutationJournal = {}

function ActionMutationJournal.new(): ActionMutationJournal
	local observers: { Observer } = {}
	local journal: ActionMutationJournal = {} :: ActionMutationJournal

	function journal:Observe(callback: ({ ActionTypes.ActionReplicationMutation }) -> ()): () -> ()
		local observer: Observer = { callback = callback, active = true }
		table.insert(observers, observer)

		return function(): ()
			if not observer.active then
				return
			end

			observer.active = false

			local index: number? = table.find(observers, observer)
			assert(index ~= nil, "ActionMutationObserverMissing")
			table.remove(observers, index)
		end
	end

	function journal:Commit(mutations: { ActionTypes.ActionReplicationMutation }): MutationFailure?
		if #mutations == 0 then
			return nil
		end

		table.freeze(mutations)
		local failure: MutationFailure? = nil

		-- Detach the delivery set before observers can disconnect or register.
		for _, observer: Observer in table.clone(observers) do
			if observer.active then
				local success: boolean, _first: any, _second: any, kind: string?, detail: any =
					Hooks.RunNonSuspending(observer.callback, mutations)

				if not success and failure == nil then
					failure = { value = if kind == "Yielded" then "ActionMutationObserverYielded" else detail }
				end
			end
		end

		return failure
	end

	function journal:Destroy(): ()
		for _, observer: Observer in observers do
			observer.active = false
		end

		table.clear(observers)
	end

	return journal
end

return ActionMutationJournal
