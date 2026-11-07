--!strict
local Types = require(script.Parent.types)
local ActionTypes = require(script.Parent.Parent.Action.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local NetworkingTypes = require(script.Parent.Parent.Networking.types)
local CommandContext = require(script.Parent.Parent.Networking.utils.CommandContext)
local ActionRequestTypes = require(script.Parent.Parent.Parent.shared.ActionRequest.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(script.Parent.Parent.Parent.shared.Networking.Schema)
local CommandConstants = require(script.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)
local Constants = require(script.Parent.Parent.Parent.shared.ActionRequest.utils.ActionRequestConstants)
local PayloadCodec = require(script.Parent.Parent.Parent.shared.ActionRequest.utils.ActionPayloadCodec)
local ReceiptLedger = require(script.Parent.ActionReceiptLedger)

type InternalActionController = ActionTypes.InternalActionController

-- Identifies one receipt inside the ledger: the exact connection generation and the
-- original Start request ID.
type ReceiptKey = { connection: unknown, requestId: number }

-- One mutation subscription per ActionController with tracked receipts. Live receipts
-- are indexed by sequence so terminal mutations retire exactly the original activation.
type Watch = {
	disconnect: () -> (),
	live: { [number]: ReceiptKey },
	liveCount: number,
	starting: number,
}

-- The guarded Start that just passed its fence. The controller commits without consumer
-- work after the guard, so its next Started mutation for this Action is this receipt's.
type Armed = { controller: InternalActionController, actionId: string, key: ReceiptKey }

type State = {
	catalog: ActionRequestTypes.ActionRequestCatalog,
	dependencies: Types.ActionRequestRuntimeDependencies,
	receipts: Types.ActionReceiptLedger,
	definitions: { NetworkingTypes.CommandDefinition },
	watches: { [InternalActionController]: Watch },
	closers: { [unknown]: () -> () },
	armed: Armed?,
	destroyed: boolean,
}

local ActionRequestRuntime = {}
ActionRequestRuntime.__index = ActionRequestRuntime

type Runtime = typeof(setmetatable({} :: State, ActionRequestRuntime))

-- Applied to Interrupt-policy Actions whose original connection closed.
local DISCONNECT_INTERRUPT_REASON: string = "ActionRequestDisconnected"

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

local function rejected(reason: string): NetworkingTypes.CommandHandlerResult
	return { accepted = false, reason = reason }
end

-- Consumer denials cross the wire only when they fit the N9 result reason contract.
local function bounded(reason: any, fallback: string): string
	if
		type(reason) == "string"
		and #reason > 0
		and #reason <= CommandConstants.MAX_REASON_BYTES
		and utf8.len(reason) ~= nil
	then
		return reason
	end

	return fallback
end

local function allowAll(_context: NetworkingTypes.CommandContext, _request: any): (boolean, string?)
	return true, nil
end

function ActionRequestRuntime._controls(self: Runtime, context: NetworkingTypes.CommandContext): boolean
	if CommandContext.IsOwner(context) then
		return true
	end

	-- Delegated control is only consulted for the current connection generation.
	local authority: Types.ActionControlAuthority? = self.dependencies.AuthorizeControl

	if authority == nil or not CommandContext.IsReady(context) then
		return false
	end

	local completed: boolean, allowed: any = pcall(authority, context.player, context.actor :: ActorTypes.Actor)

	return completed and allowed == true
end

function ActionRequestRuntime._retire(self: Runtime, controller: InternalActionController, sequenceId: number): ()
	local watch: Watch? = self.watches[controller]
	local key: ReceiptKey? = if watch ~= nil then watch.live[sequenceId] else nil

	if watch == nil or key == nil then
		return
	end

	watch.live[sequenceId] = nil
	watch.liveCount -= 1
	self.receipts:Retire(key.connection, key.requestId)
	self:_release(controller)
end

function ActionRequestRuntime._activate(
	self: Runtime,
	controller: InternalActionController,
	key: ReceiptKey,
	sequenceId: number
): ()
	local watch: Watch? = self.watches[controller]

	if watch == nil or not self.receipts:Activate(key.connection, key.requestId, sequenceId) then
		return
	end

	watch.live[sequenceId] = key
	watch.liveCount += 1
end

function ActionRequestRuntime._observe(
	self: Runtime,
	controller: InternalActionController,
	mutations: { ActionTypes.ActionReplicationMutation }
): ()
	for _, mutation: ActionTypes.ActionReplicationMutation in mutations do
		local armed: Armed? = self.armed

		if mutation.kind ~= "Started" then
			self:_retire(controller, mutation.sequenceId)
		elseif armed ~= nil and armed.controller == controller and armed.actionId == mutation.actionId then
			self.armed = nil
			self:_activate(controller, armed.key, mutation.sequenceId)
		end
	end
end

function ActionRequestRuntime._watch(self: Runtime, controller: InternalActionController): Watch
	local existing: Watch? = self.watches[controller]

	if existing ~= nil then
		return existing
	end

	local disconnect: () -> () = controller:_observeMutations(
		function(mutations: { ActionTypes.ActionReplicationMutation }): ()
			self:_observe(controller, mutations)
		end
	)

	local watch: Watch = { disconnect = disconnect, live = {}, liveCount = 0, starting = 0 }

	self.watches[controller] = watch

	return watch
end

function ActionRequestRuntime._release(self: Runtime, controller: InternalActionController): ()
	local watch: Watch? = self.watches[controller]

	if watch ~= nil and watch.liveCount == 0 and watch.starting == 0 then
		self.watches[controller] = nil
		watch.disconnect()
	end
end

-- Runs synchronously while N9 closes the generation. Every receipt is removed before
-- any Interrupt so author callbacks observe a ledger that no longer accepts follow-ups.
function ActionRequestRuntime._close(self: Runtime, connection: unknown): ()
	self.closers[connection] = nil

	local removed: { Types.ActionReceiptSnapshot } = self.receipts:CloseConnection(connection)
	local interrupts: { { controller: InternalActionController, sequenceId: number } } = {}
	local affected: { [InternalActionController]: boolean } = {}

	for _, snapshot: Types.ActionReceiptSnapshot in removed do
		local sequenceId: number? = snapshot.sequenceId
		local controller: InternalActionController? = self.dependencies.GetActionController(snapshot.actor)
		local watch: Watch? = if controller ~= nil then self.watches[controller] else nil

		if sequenceId ~= nil and controller ~= nil and watch ~= nil and watch.live[sequenceId] ~= nil then
			watch.live[sequenceId] = nil
			watch.liveCount -= 1
			affected[controller] = true

			if snapshot.onDisconnect == "Interrupt" then
				table.insert(interrupts, { controller = controller, sequenceId = sequenceId })
			end
		end
	end

	for _, interrupt in interrupts do
		pcall(
			interrupt.controller.InterruptAction,
			interrupt.controller,
			interrupt.sequenceId,
			DISCONNECT_INTERRUPT_REASON
		)
	end

	for controller: InternalActionController in affected do
		self:_release(controller)
	end
end

function ActionRequestRuntime._connection(self: Runtime, context: NetworkingTypes.CommandContext): unknown?
	local connection: unknown? = CommandContext.GetConnection(context)

	if connection == nil or self.closers[connection] ~= nil then
		return connection
	end

	local observed: unknown = connection

	local disconnect: (() -> ())? = CommandContext.ObserveConnectionClosing(context, function(): ()
		self:_close(observed)
	end)

	if disconnect == nil then
		return nil
	end

	self.closers[connection] = disconnect

	return connection
end

function ActionRequestRuntime._authorizeStart(
	self: Runtime,
	context: NetworkingTypes.CommandContext,
	request: any
): (boolean, string?)
	local compiled: ActionRequestTypes.CompiledActionRequest? = self.catalog.requestsById[request.actionId]

	if self.destroyed then
		return false, "ActionRequestRuntimeDestroyed"
	elseif compiled == nil then
		return false, "ActionRequestUnregistered"
	elseif compiled.contractTag ~= request.contractTag then
		return false, "ActionContractMismatch"
	elseif not self:_controls(context) then
		return false, "ActorNotOwned"
	end

	return true, nil
end

function ActionRequestRuntime._start(
	self: Runtime,
	context: NetworkingTypes.CommandContext,
	request: any
): NetworkingTypes.CommandHandlerResult
	local compiled: ActionRequestTypes.CompiledActionRequest = self.catalog.requestsById[request.actionId]

	local decoded: boolean, parameters: any, payloadReason: string? =
		PayloadCodec.Decode(compiled.start, request.payload)

	if not decoded then
		return rejected(payloadReason or "ActionPayloadMalformed")
	end

	local actor: ActorTypes.Actor = context.actor :: ActorTypes.Actor
	local controller: InternalActionController? = self.dependencies.GetActionController(actor)

	if controller == nil then
		return rejected("ActionControllerUnavailable")
	end

	local connection: unknown? = self:_connection(context)

	if connection == nil then
		return rejected("ActionRequestConnectionClosed")
	end

	local key: ReceiptKey = { connection = connection, requestId = context.requestId }

	local reserved: boolean, reserveReason: string? = self.receipts:Reserve(connection, context.requestId, {
		player = context.player,
		actor = actor,
		actionId = compiled.actionId,
		allowsStop = compiled.stop ~= nil,
		allowsInterrupt = compiled.allowInputInterrupt,
		onDisconnect = compiled.onDisconnect,
	})

	if not reserved then
		return rejected(reserveReason or "ActionReceiptCapacityReached")
	end

	local watch: Watch = self:_watch(controller)
	watch.starting += 1

	local result: ActionTypes.ActionRequestResult = controller:_requestGuardedAction(
		compiled.actionId,
		parameters,
		function(): string?
			-- Authored callbacks may have closed the connection or revoked control.
			if self.destroyed or self.receipts:Get(connection, context.requestId) == nil then
				return "ActionRequestConnectionClosed"
			elseif not self:_controls(context) then
				return "ActorNotOwned"
			end

			self.armed = { controller = controller, actionId = compiled.actionId, key = key }

			return nil
		end
	)

	self.armed = nil
	watch.starting -= 1

	if not result.accepted then
		self.receipts:Retire(connection, context.requestId)
		self:_release(controller)

		return rejected(bounded(result.reason, "ActionRequestRejected"))
	end

	self:_release(controller)

	return { accepted = true, result = { sequenceId = result.sequenceId } }
end

function ActionRequestRuntime._followUp(
	self: Runtime,
	context: NetworkingTypes.CommandContext,
	originalStartRequestId: number
): (Types.ActionReceiptSnapshot?, InternalActionController?)
	local connection: unknown? = if self.destroyed then nil else CommandContext.GetConnection(context)

	local snapshot: Types.ActionReceiptSnapshot? = if connection ~= nil
		then self.receipts:Get(connection, originalStartRequestId)
		else nil

	if snapshot == nil or snapshot.state ~= "Live" then
		return nil, nil
	end

	return snapshot, self.dependencies.GetActionController(snapshot.actor)
end

function ActionRequestRuntime._stop(
	self: Runtime,
	context: NetworkingTypes.CommandContext,
	request: any
): NetworkingTypes.CommandHandlerResult
	local snapshot: Types.ActionReceiptSnapshot?, controller: InternalActionController? =
		self:_followUp(context, request.originalStartRequestId)

	if snapshot == nil or controller == nil then
		return rejected("ActionReceiptUnknown")
	end

	local stop: ActionRequestTypes.CompiledActionPayload? = self.catalog.requestsById[snapshot.actionId].stop

	if not snapshot.allowsStop or stop == nil then
		return rejected("ActionStopUnavailable")
	end

	local decoded: boolean, parameters: any, payloadReason: string? = PayloadCodec.Decode(stop, request.payload)

	if not decoded then
		return rejected(payloadReason or "ActionPayloadMalformed")
	end

	local connection: unknown = CommandContext.GetConnection(context)

	-- Marked before delivery so a reentrant duplicate can never reach the hook twice.
	if not self.receipts:MarkStopDelivered(connection, snapshot.requestId) then
		return rejected("ActionStopAlreadyDelivered")
	end

	local stopped: boolean, stopReason: string? = controller:RequestStop(snapshot.sequenceId :: number, parameters)

	if not stopped then
		return rejected(bounded(stopReason, "ActionStopRejected"))
	end

	return { accepted = true }
end

function ActionRequestRuntime._interrupt(
	self: Runtime,
	context: NetworkingTypes.CommandContext,
	request: any
): NetworkingTypes.CommandHandlerResult
	local snapshot: Types.ActionReceiptSnapshot?, controller: InternalActionController? =
		self:_followUp(context, request.originalStartRequestId)

	if snapshot == nil or controller == nil then
		return rejected("ActionReceiptUnknown")
	elseif not snapshot.allowsInterrupt then
		return rejected("ActionInterruptNotAllowed")
	end

	local interrupted: boolean, interruptReason: string? =
		controller:InterruptAction(snapshot.sequenceId :: number, request.reason)

	if not interrupted then
		return rejected(bounded(interruptReason, "ActionInterruptRejected"))
	end

	return { accepted = true }
end

function ActionRequestRuntime.GetCommandDefinitions(self: Runtime): { NetworkingTypes.CommandDefinition }
	return self.definitions
end

function ActionRequestRuntime._GetReceiptCountForTests(self: Runtime): number
	return self.receipts:GetCount()
end

-- Releases framework bookkeeping only; running Actions stay with their controllers.
function ActionRequestRuntime.Destroy(self: Runtime): ()
	if self.destroyed then
		return
	end

	self.destroyed = true
	self.armed = nil

	for _, disconnect: () -> () in self.closers do
		disconnect()
	end

	for _, watch: Watch in self.watches do
		watch.disconnect()
	end

	table.clear(self.closers)
	table.clear(self.watches)
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
			definitions = {},
			watches = {},
			closers = {},
			armed = nil,
			destroyed = false,
		}

		local self: Runtime = setmetatable(state, ActionRequestRuntime)

		local definitions: { NetworkingTypes.CommandDefinition } = {
			{
				id = Constants.START_COMMAND_ID,
				target = "Actor",
				request = startRequest,
				result = startResult,
				authorize = function(context: NetworkingTypes.CommandContext, request: any): (boolean, string?)
					return self:_authorizeStart(context, request)
				end,
				handle = function(context: NetworkingTypes.CommandContext, request: any)
					return self:_start(context, request)
				end,
			},
			{
				id = Constants.STOP_COMMAND_ID,
				target = "None",
				request = stopRequest,
				authorize = allowAll,
				handle = function(context: NetworkingTypes.CommandContext, request: any)
					return self:_stop(context, request)
				end,
			},
			{
				id = Constants.INTERRUPT_COMMAND_ID,
				target = "None",
				request = interruptRequest,
				authorize = allowAll,
				handle = function(context: NetworkingTypes.CommandContext, request: any)
					return self:_interrupt(context, request)
				end,
			},
		}

		state.definitions = table.freeze(definitions)

		return self :: Types.ServerActionRequestRuntime
	end,
}

return table.freeze(module)
