--!strict
local Types = require(script.Parent.Parent.types)

export type Owner = {
	Remember: (Types.ActionFollowUpIntent) -> (),
	Remove: (number) -> (),
	Get: (number) -> Types.ActionFollowUpIntent?,
	Complete: (number, Types.ActionFollowUpIntent?) -> (),
	Drain: () -> (),
	Destroy: () -> (),
}

local Queue = {}

function Queue.IsPressure(reason: string?): boolean
	return reason == "CommandPendingFull" or reason == "ActionRequestCapacityReached" or reason == "ClientNotReady"
end

-- Owns only encoded, not-admitted intentions. Admitted/Unknown requests never enter.
function Queue.new(send: (Types.ActionFollowUpIntent) -> (number?, string?)): Owner
	local pending: { [number]: Types.ActionFollowUpIntent } = {}
	local draining: boolean = false
	local destroyed: boolean = false

	return {
		Remember = function(intent): ()
			local previous: Types.ActionFollowUpIntent? = pending[intent.originalStartRequestId]

			if not destroyed and (previous == nil or intent.kind == "Interrupt") then
				pending[intent.originalStartRequestId] = intent
			end
		end,
		Remove = function(original: number): ()
			pending[original] = nil
		end,
		Get = function(original: number): Types.ActionFollowUpIntent?
			return pending[original]
		end,
		Complete = function(original: number, prior: Types.ActionFollowUpIntent?): ()
			if pending[original] == prior then
				pending[original] = nil
			end
		end,
		Drain = function(): ()
			if draining or destroyed then
				return
			end

			draining = true
			local snapshot: { [number]: Types.ActionFollowUpIntent } = table.clone(pending)

			local originals: { number } = {}

			for original: number in snapshot do
				table.insert(originals, original)
			end

			table.sort(originals)

			for _, original: number in originals do
				local intent: Types.ActionFollowUpIntent = snapshot[original]

				if pending[original] ~= intent or destroyed then
					continue
				end

				pending[original] = nil
				local requestId: number?, reason: string? = send(intent)

				if not destroyed and requestId == nil and Queue.IsPressure(reason) and pending[original] == nil then
					pending[original] = intent
				end
			end

			draining = false
		end,
		Destroy = function(): ()
			destroyed = true
			table.clear(pending)
		end,
	}
end

return Queue
