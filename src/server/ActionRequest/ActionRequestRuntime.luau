--!strict
local Types = require(script.Parent.types)
local NetworkingTypes = require(script.Parent.Parent.Networking.types)
local ActionRequestTypes = require(script.Parent.Parent.Parent.shared.ActionRequest.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(script.Parent.Parent.Parent.shared.Networking.Schema)
local Constants = require(script.Parent.Parent.Parent.shared.ActionRequest.utils.ActionRequestConstants)
local ReceiptLedger = require(script.Parent.ActionReceiptLedger)

type State = {
	catalog: ActionRequestTypes.ActionRequestCatalog,
	dependencies: Types.ActionRequestRuntimeDependencies,
	receipts: Types.ActionReceiptLedger,
	definitions: { NetworkingTypes.CommandDefinition },
	destroyed: boolean,
}

local ActionRequestRuntime = {}
ActionRequestRuntime.__index = ActionRequestRuntime

type Runtime = typeof(setmetatable({} :: State, ActionRequestRuntime))

local startRequest: SharedNetworkingTypes.SchemaDefinition = Schema.Struct({
	actionId = Schema.String(Constants.MAX_ACTION_ID_BYTES),
	contractTag = Schema.U32,
	payload = Schema.String(Constants.MAX_PAYLOAD_BYTES),
})

local startResult: SharedNetworkingTypes.SchemaDefinition = Schema.Struct({ sequenceId = Schema.U32 })

local stopRequest: SharedNetworkingTypes.SchemaDefinition = Schema.Struct({
	originalStartRequestId = Schema.U32,
	payload = Schema.String(Constants.MAX_PAYLOAD_BYTES),
})

local interruptRequest: SharedNetworkingTypes.SchemaDefinition = Schema.Struct({
	originalStartRequestId = Schema.U32,
	reason = Schema.Enum(table.clone(Constants.INTERRUPT_REASONS)),
})

-- I5 TDD scaffold. Original-connection authority, inner decoding, receipts and the
-- guarded ActionController Start remain unimplemented; every request is refused pre-effect.
local function unavailable(_context: NetworkingTypes.CommandContext, _request: any): (boolean, string?)
	return false, "ActionRequestUnavailable"
end

local function refuse(_context: NetworkingTypes.CommandContext, _request: any): NetworkingTypes.CommandHandlerResult
	return { accepted = false, reason = "ActionRequestUnavailable" }
end

function ActionRequestRuntime.GetCommandDefinitions(self: Runtime): { NetworkingTypes.CommandDefinition }
	return self.definitions
end

function ActionRequestRuntime._GetReceiptCountForTests(self: Runtime): number
	return self.receipts:GetCount()
end

function ActionRequestRuntime.Destroy(self: Runtime): ()
	if self.destroyed then
		return
	end

	self.destroyed = true
	self.receipts:Destroy()
end

local module: Types.ActionRequestRuntimeModule = {
	new = function(
		catalog: ActionRequestTypes.ActionRequestCatalog,
		dependencies: Types.ActionRequestRuntimeDependencies,
		options: Types.ActionRequestRuntimeOptions?
	): Types.ServerActionRequestRuntime
		local state: State = {
			catalog = catalog,
			dependencies = dependencies,
			receipts = ReceiptLedger.new(if options ~= nil then options.receiptLimits else nil),
			definitions = table.freeze({
				{
					id = Constants.START_COMMAND_ID,
					target = "Actor",
					request = startRequest,
					result = startResult,
					authorize = unavailable,
					handle = refuse,
				},
				{
					id = Constants.STOP_COMMAND_ID,
					target = "None",
					request = stopRequest,
					authorize = unavailable,
					handle = refuse,
				},
				{
					id = Constants.INTERRUPT_COMMAND_ID,
					target = "None",
					request = interruptRequest,
					authorize = unavailable,
					handle = refuse,
				},
			} :: { NetworkingTypes.CommandDefinition }),
			destroyed = false,
		}

		return setmetatable(state, ActionRequestRuntime) :: Types.ServerActionRequestRuntime
	end,
}

return table.freeze(module)
