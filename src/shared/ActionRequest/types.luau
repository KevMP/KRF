--!strict
local NetworkingTypes = require(script.Parent.Parent.Networking.types)

local types = {}

-- Consumer-authored replicated wire metadata shared by Server.Init and Client.Init.
-- It holds no callbacks, grants or client input policy; registration is not a grant.
export type ActionDisconnectPolicy = "Keep" | "Interrupt"

-- An absent Stop schema means no Stop path. An empty table is a parameterless Stop.
export type ActionStopSchema = { parameters: NetworkingTypes.SchemaDefinition? }

export type ActionRequestSchema = {
	start: NetworkingTypes.SchemaDefinition?,
	stop: ActionStopSchema?,
	allowInputInterrupt: boolean?,
	requiresClientRelease: boolean?,
	onDisconnect: ActionDisconnectPolicy?,
}

export type ActionRequestSchemas = { [string]: ActionRequestSchema }

-- Closed KRF.Action.Interrupt vocabulary. A reason never proves current world state.
export type ActionInputInterruptReason =
	"RouteInvalidated"
	| "ContextDisabled"
	| "ActorSwitched"
	| "FocusLost"
	| "StopPreparationFailed"
	| "ClientShutdown"

-- Framework-private compiled contracts. Codecs are compiled once per Action at startup.
export type CompiledActionPayload = {
	read schema: NetworkingTypes.CompiledSchema?,
	read codec: NetworkingTypes.CompiledCodec?,
}

export type CompiledActionRequest = {
	read actionId: string,
	read contractTag: number,
	read start: CompiledActionPayload,
	-- Nil when the Action declares no Stop path.
	read stop: CompiledActionPayload?,
	read allowInputInterrupt: boolean,
	read requiresClientRelease: boolean,
	read onDisconnect: ActionDisconnectPolicy,
}

export type ActionRequestCatalog = {
	read actionIds: { string },
	read requestsById: { [string]: CompiledActionRequest },
}

export type ActionRequestCatalogModule = {
	read Compile: (schemas: any) -> (ActionRequestCatalog?, string?),
}

-- Inner payloads travel as bounded binary strings inside fixed N9 String fields.
-- Decode requires complete consumption; a nil decoded value is valid when ok is true.
export type ActionPayloadCodecModule = {
	read Encode: (payload: CompiledActionPayload, value: any) -> (string?, string?),
	read Decode: (payload: CompiledActionPayload, encoded: any) -> (boolean, any, string?),
}

export type ActionContractTagModule = {
	read Compute: (
		actionId: string,
		start: NetworkingTypes.CompiledSchema?,
		stop: CompiledActionPayload?,
		allowInputInterrupt: boolean,
		requiresClientRelease: boolean,
		onDisconnect: ActionDisconnectPolicy
	) -> number,
	-- The canonical form both peers hash; equal descriptions mean identical wire contracts.
	read Describe: (schema: NetworkingTypes.CompiledSchema?) -> string,
}

return types
