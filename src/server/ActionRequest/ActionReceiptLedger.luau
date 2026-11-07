--!strict
local Types = require(script.Parent.types)

type State = {
	limits: Types.ActionReceiptLimits,
}

local ActionReceiptLedger = {}
ActionReceiptLedger.__index = ActionReceiptLedger

type Ledger = typeof(setmetatable({} :: State, ActionReceiptLedger))

-- I5 TDD scaffold. Bounded provisional/live receipt storage remains unimplemented.
function ActionReceiptLedger.Reserve(
	_self: Ledger,
	_connection: unknown,
	_requestId: number,
	_binding: Types.ActionReceiptBinding
): (boolean, string?)
	return false, "ActionReceiptLedgerUnavailable"
end

function ActionReceiptLedger.Activate(
	_self: Ledger,
	_connection: unknown,
	_requestId: number,
	_sequenceId: number
): boolean
	return false
end

function ActionReceiptLedger.Retire(_self: Ledger, _connection: unknown, _requestId: number): () end

function ActionReceiptLedger.MarkStopDelivered(_self: Ledger, _connection: unknown, _requestId: number): boolean
	return false
end

function ActionReceiptLedger.Get(_self: Ledger, _connection: unknown, _requestId: number): Types.ActionReceiptSnapshot?
	return nil
end

function ActionReceiptLedger.CloseConnection(_self: Ledger, _connection: unknown): { Types.ActionReceiptSnapshot }
	return {}
end

function ActionReceiptLedger.GetCount(_self: Ledger, _connection: unknown?): number
	return 0
end

function ActionReceiptLedger.Destroy(_self: Ledger): () end

local module: Types.ActionReceiptLedgerModule = {
	new = function(limits: Types.ActionReceiptLimits?): Types.ActionReceiptLedger
		local state: State = { limits = limits or {} }

		return setmetatable(state, ActionReceiptLedger) :: Types.ActionReceiptLedger
	end,
}

return table.freeze(module)
