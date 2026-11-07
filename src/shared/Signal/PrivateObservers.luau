--!strict
export type Entry<Callback> = { callback: Callback, active: boolean }

export type Registry<Callback> = {
	Add: (callback: Callback) -> () -> (),
	Snapshot: (matches: ((Callback) -> boolean)?) -> { Entry<Callback> },
	IsEmpty: (matches: ((Callback) -> boolean)?) -> boolean,
	Destroy: () -> (),
}

local Observers = {}

function Observers.new<Callback>(maximum: number, reason: string): Registry<Callback>
	local entries: { Entry<Callback> } = {}
	local destroyed: boolean = false

	return {
		Add = function(callback: Callback): () -> ()
			assert(not destroyed, "ClientNotReady")
			assert(#entries < maximum, reason)
			local entry: Entry<Callback> = { callback = callback, active = true }
			table.insert(entries, entry)

			return function(): ()
				if not entry.active then
					return
				end

				entry.active = false

				local index: number = assert(table.find(entries, entry), "Expected registered input observer")
				table.remove(entries, index)
			end
		end,
		Snapshot = function(matches: ((Callback) -> boolean)?): { Entry<Callback> }
			if matches == nil then
				return table.clone(entries)
			end

			local selected: { Entry<Callback> } = {}

			for _, entry: Entry<Callback> in entries do
				if matches(entry.callback) then
					table.insert(selected, entry)
				end
			end

			return selected
		end,
		IsEmpty = function(matches: ((Callback) -> boolean)?): boolean
			if matches == nil then
				return #entries == 0
			end

			for _, entry: Entry<Callback> in entries do
				if matches(entry.callback) then
					return false
				end
			end

			return true
		end,
		Destroy = function(): ()
			destroyed = true

			for _, entry in entries do
				entry.active = false
			end

			table.clear(entries)
		end,
	}
end

function Observers.Run(callback: (...any) -> ...any, ...: any): (boolean, string?, any, any)
	local worker: thread = coroutine.create(callback)
	local success: boolean, result: any, reason: any = coroutine.resume(worker, ...)

	if coroutine.status(worker) ~= "dead" then
		pcall(task.cancel, worker)
		pcall(coroutine.close, worker)

		return false, "Yielded", nil, nil
	end

	return success,
		if success then nil else if type(result) == "string" then result else "NonStringError",
		result,
		reason
end

return Observers
