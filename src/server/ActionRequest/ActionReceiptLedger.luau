--!strict
local Types = require(script.Parent.types)

-- Private capacity bounds. A held Action needs one receipt per live client activation.
local DEFAULT_MAX_CONNECTION_RECEIPTS: number = 64
local DEFAULT_MAX_GLOBAL_RECEIPTS: number = 16384

type Receipt = {
	binding: Types.ActionReceiptBinding,
	requestId: number,
	state: Types.ActionReceiptState,
	sequenceId: number?,
	stopDelivered: boolean,
}

type State = {
	maxConnection: number,
	maxGlobal: number,
	connections: { [unknown]: { [number]: Receipt } },
	counts: { [unknown]: number },
	count: number,
	destroyed: boolean,
}

local ActionReceiptLedger = {}
ActionReceiptLedger.__index = ActionReceiptLedger

type Ledger = typeof(setmetatable({} :: State, ActionReceiptLedger))

local function snapshot(receipt: Receipt): Types.ActionReceiptSnapshot
	local binding: Types.ActionReceiptBinding = receipt.binding

	return table.freeze({
		player = binding.player,
		actor = binding.actor,
		actionId = binding.actionId,
		allowsStop = binding.allowsStop,
		allowsInterrupt = binding.allowsInterrupt,
		onDisconnect = binding.onDisconnect,
		requestId = receipt.requestId,
		state = receipt.state,
		sequenceId = receipt.sequenceId,
		stopDelivered = receipt.stopDelivered,
	})
end

local function limit(value: number?, default: number): number
	local resolved: number = if value == nil then default else value
	assert(type(resolved) == "number" and resolved >= 1 and resolved % 1 == 0, "InvalidActionReceiptLimit")

	return resolved
end

function ActionReceiptLedger._find(self: Ledger, connection: unknown, requestId: number): Receipt?
	local receipts: { [number]: Receipt }? = self.connections[connection]

	return if receipts ~= nil then receipts[requestId] else nil
end

function ActionReceiptLedger.Reserve(
	self: Ledger,
	connection: unknown,
	requestId: number,
	binding: Types.ActionReceiptBinding
): (boolean, string?)
	if self.destroyed then
		return false, "ActionReceiptLedgerDestroyed"
	elseif self:_find(connection, requestId) ~= nil then
		return false, "ActionReceiptDuplicate"
	elseif (self.counts[connection] or 0) >= self.maxConnection then
		return false, "ActionReceiptCapacityReached"
	elseif self.count >= self.maxGlobal then
		return false, "ActionReceiptGlobalCapacityReached"
	end

	local receipts: { [number]: Receipt } = self.connections[connection] or {}

	self.connections[connection] = receipts

	receipts[requestId] = {
		binding = table.freeze(table.clone(binding)),
		requestId = requestId,
		state = "Provisional",
		sequenceId = nil,
		stopDelivered = false,
	}

	self.counts[connection] = (self.counts[connection] or 0) + 1
	self.count += 1

	return true, nil
end

function ActionReceiptLedger.Activate(self: Ledger, connection: unknown, requestId: number, sequenceId: number): boolean
	local receipt: Receipt? = self:_find(connection, requestId)

	if receipt == nil or receipt.state ~= "Provisional" then
		return false
	end

	receipt.state = "Live"
	receipt.sequenceId = sequenceId

	return true
end

function ActionReceiptLedger.Retire(self: Ledger, connection: unknown, requestId: number): ()
	local receipts: { [number]: Receipt }? = self.connections[connection]

	if receipts == nil or receipts[requestId] == nil then
		return
	end

	receipts[requestId] = nil
	self.count -= 1

	local remaining: number = self.counts[connection] - 1

	if remaining == 0 then
		self.connections[connection] = nil
		self.counts[connection] = nil
	else
		self.counts[connection] = remaining
	end
end

function ActionReceiptLedger.MarkStopDelivered(self: Ledger, connection: unknown, requestId: number): boolean
	local receipt: Receipt? = self:_find(connection, requestId)

	if receipt == nil or receipt.state ~= "Live" or receipt.stopDelivered then
		return false
	end

	receipt.stopDelivered = true

	return true
end

function ActionReceiptLedger.Get(self: Ledger, connection: unknown, requestId: number): Types.ActionReceiptSnapshot?
	local receipt: Receipt? = self:_find(connection, requestId)

	return if receipt ~= nil then snapshot(receipt) else nil
end

function ActionReceiptLedger.CloseConnection(self: Ledger, connection: unknown): { Types.ActionReceiptSnapshot }
	local receipts: { [number]: Receipt }? = self.connections[connection]

	if receipts == nil then
		return {}
	end

	local removed: { Types.ActionReceiptSnapshot } = {}

	for _, receipt: Receipt in receipts do
		table.insert(removed, snapshot(receipt))
	end

	table.sort(removed, function(first: Types.ActionReceiptSnapshot, second: Types.ActionReceiptSnapshot): boolean
		return first.requestId < second.requestId
	end)

	self.count -= self.counts[connection]
	self.connections[connection] = nil
	self.counts[connection] = nil

	return removed
end

function ActionReceiptLedger.GetCount(self: Ledger, connection: unknown?): number
	if connection == nil then
		return self.count
	end

	return self.counts[connection] or 0
end

function ActionReceiptLedger.Destroy(self: Ledger): ()
	self.destroyed = true
	table.clear(self.connections)
	table.clear(self.counts)
	self.count = 0
end

local module: Types.ActionReceiptLedgerModule = {
	new = function(limits: Types.ActionReceiptLimits?): Types.ActionReceiptLedger
		local options: Types.ActionReceiptLimits = limits or {}

		local state: State = {
			maxConnection = limit(options.maxConnectionReceipts, DEFAULT_MAX_CONNECTION_RECEIPTS),
			maxGlobal = limit(options.maxGlobalReceipts, DEFAULT_MAX_GLOBAL_RECEIPTS),
			connections = {},
			counts = {},
			count = 0,
			destroyed = false,
		}

		return setmetatable(state, ActionReceiptLedger) :: Types.ActionReceiptLedger
	end,
}

return table.freeze(module)
