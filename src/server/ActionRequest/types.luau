--!strict
local ActorTypes = require(script.Parent.Parent.Actor.types)
local ActionTypes = require(script.Parent.Parent.Action.types)
local NetworkingTypes = require(script.Parent.Parent.Networking.types)
local ActionRequestTypes = require(script.Parent.Parent.Parent.shared.ActionRequest.types)

local types = {}

-- Optional server-only authority for delegated control such as mounts or possession.
-- It never grants Actions; ActionController grants and onCanStart stay authoritative.
export type ActionControlAuthority = (player: Player, actor: ActorTypes.Actor) -> boolean

-- Receipts are keyed by the exact N9 connection generation and original Start request ID.
-- The connection token is opaque N9 identity and is never reused by a later connection.
export type ActionReceiptState = "Provisional" | "Live"

export type ActionReceiptBinding = {
	read player: Player,
	read actor: ActorTypes.Actor,
	read actionId: string,
	read allowsStop: boolean,
	read allowsInterrupt: boolean,
	read onDisconnect: ActionRequestTypes.ActionDisconnectPolicy,
}

export type ActionReceiptSnapshot = ActionReceiptBinding & {
	read requestId: number,
	read state: ActionReceiptState,
	read sequenceId: number?,
	read stopDelivered: boolean,
}

export type ActionReceiptLimits = {
	maxConnectionReceipts: number?,
	maxGlobalReceipts: number?,
}

export type ActionReceiptLedger = {
	Reserve: (
		self: ActionReceiptLedger,
		connection: unknown,
		requestId: number,
		binding: ActionReceiptBinding
	) -> (boolean, string?),
	Activate: (self: ActionReceiptLedger, connection: unknown, requestId: number, sequenceId: number) -> boolean,
	Retire: (self: ActionReceiptLedger, connection: unknown, requestId: number) -> (),
	-- True only for the first delivery; later duplicates must not reach onStopRequested.
	MarkStopDelivered: (self: ActionReceiptLedger, connection: unknown, requestId: number) -> boolean,
	Get: (self: ActionReceiptLedger, connection: unknown, requestId: number) -> ActionReceiptSnapshot?,
	-- Removes every receipt of one generation and returns the removed snapshots in request order.
	CloseConnection: (self: ActionReceiptLedger, connection: unknown) -> { ActionReceiptSnapshot },
	GetCount: (self: ActionReceiptLedger, connection: unknown?) -> number,
	Destroy: (self: ActionReceiptLedger) -> (),
}

export type ActionReceiptLedgerModule = {
	read new: (limits: ActionReceiptLimits?) -> ActionReceiptLedger,
}

export type ActionRequestRuntimeDependencies = {
	GetActionController: (ActorTypes.Actor) -> ActionTypes.InternalActionController?,
	-- Default authority is the current N9 OwnerActor association.
	AuthorizeControl: ActionControlAuthority?,
}

export type ActionRequestRuntimeOptions = {
	receiptLimits: ActionReceiptLimits?,
}

export type ServerActionRequestRuntime = {
	-- Exactly the three fixed commands, ready to merge with consumer commands.
	GetCommandDefinitions: (self: ServerActionRequestRuntime) -> { NetworkingTypes.CommandDefinition },
	-- Stop and Interrupt, which N9 admits through its protected follow-up reserve.
	GetFollowUpCommandIds: (self: ServerActionRequestRuntime) -> { string },
	_GetReceiptCountForTests: (self: ServerActionRequestRuntime) -> number,
	Destroy: (self: ServerActionRequestRuntime) -> (),
}

export type ActionRequestRuntimeModule = {
	read new: (
		catalog: ActionRequestTypes.ActionRequestCatalog,
		dependencies: ActionRequestRuntimeDependencies,
		options: ActionRequestRuntimeOptions?
	) -> ServerActionRequestRuntime,
}

export type ActionRequestValidatorModule = {
	-- Every registered request id must name an Action in the prepared catalog.
	read ValidateCatalog: (
		catalog: ActionRequestTypes.ActionRequestCatalog,
		actions: ActionTypes.PreparedActionCatalog
	) -> (boolean, string?),
	-- The fixed Action command ids stay reserved even when request schemas are omitted.
	read ValidateReservedCommands: (commands: any) -> (boolean, string?),
}

return types
