--!strict
local Limits = require(script.Parent.ActionRouteLimits)

export type Store<Record> = {
	CanCreate: () -> boolean,
	Create: (Record) -> ({ read token: unknown }?, string?),
	Take: (unknown) -> (Record?, boolean),
	Read: (unknown) -> Record?,
	Clear: () -> (),
}

local Plans = {}

-- Weak capabilities carry no mutable state. Records and disposal are private,
-- bounded. The publishing owner clears them at its generation fence; consumed
-- capabilities remain recognizable without retaining their former records.
function Plans.new<Record>(dispose: (Record) -> ()): Store<Record>
	local entries: { [unknown]: Record } = setmetatable({}, { __mode = "k" })
	local issued: { [unknown]: boolean } = setmetatable({}, { __mode = "k" })

	local function canCreate(): boolean
		local count: number = 0

		for _ in entries do
			count += 1
		end

		return count < Limits.MAX_PREPARED_PLANS
	end

	return {
		CanCreate = canCreate,
		Create = function(record: Record): ({ read token: unknown }?, string?)
			if not canCreate() then
				dispose(record)

				return nil, "ActionPlanLimitExceeded"
			end

			local token = table.freeze({ token = table.freeze({}) })

			entries[token] = record
			issued[token] = true

			return token, nil
		end,
		Read = function(token: unknown): Record?
			return if type(token) == "table" then entries[token] else nil
		end,
		Take = function(token: unknown): (Record?, boolean)
			if type(token) ~= "table" then
				return nil, false
			end

			local record: Record? = entries[token]

			entries[token] = nil

			return record, issued[token] == true
		end,
		Clear = function(): ()
			local old = table.clone(entries)
			table.clear(entries)

			for _, record: Record in old do
				dispose(record)
			end
		end,
	}
end

return Plans
