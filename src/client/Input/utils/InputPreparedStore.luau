--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.InputConstants)

export type Record = {
	generation: number,
	validators: number,
	kind: "Source" | "Epoch" | "Recognition",
	graph: Types.InputGraphSnapshot?,
	profiles: unknown,
	reason: string?,
	inputIds: { string }?,
	recognitionRevision: number?,
	consumed: boolean,
	skipValidation: boolean?,
}

export type Store = {
	Put: (Record) -> (Types.InputPlan?, string?),
	Read: (unknown) -> Record?,
	Release: (unknown) -> (),
	Clear: () -> (),
}

local Prepared = {}

-- One bounded capability store for all I1 prepared work; records are never public.
function Prepared.new(): Store
	local entries: { [unknown]: Record } = setmetatable({}, { __mode = "k" })

	return {
		Put = function(record: Record): (Types.InputPlan?, string?)
			local count: number = 0

			for _ in entries do
				count += 1
			end

			if count >= Constants.MAX_PREPARED_PLANS then
				return nil, "InputPlanLimitExceeded"
			end

			local plan: Types.InputPlan = table.freeze({ generation = record.generation, token = table.freeze({}) })

			entries[plan] = record

			return plan, nil
		end,
		Read = function(plan: unknown): Record?
			return if type(plan) == "table" then entries[plan] else nil
		end,
		Release = function(plan: unknown): ()
			if type(plan) == "table" then
				entries[plan] = nil
			end
		end,
		Clear = function(): ()
			table.clear(entries)
		end,
	}
end

return Prepared
