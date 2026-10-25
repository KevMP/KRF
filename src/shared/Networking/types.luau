--!strict
local types = {}

-- Schemas and codecs
-- Framework-private codec contract. Read limits are exclusive byte offsets.
-- A nil decoded Optional is successful when newOffset is present and reason is nil.
export type CompiledCodec = {
	read fixedSizeBytes: number?,
	read maxSizeBytes: number,
	read Measure: (value: any) -> (number?, string?),
	read Write: (value: any, destination: buffer, offset: number) -> (number?, string?),
	read Read: (source: buffer, offset: number, limit: number) -> (any?, number?, string?),
}

export type CodecCompiler = {
	Compile: (schema: CompiledSchema) -> (CompiledCodec?, string?),
}

export type PrimitiveKind = "Boolean" | "U8" | "U16" | "U32" | "I8" | "I16" | "I32" | "F32" | "F64"

export type SchemaDefinition =
	{ kind: PrimitiveKind }
	| { kind: "String", maxBytes: number }
	| { kind: "Enum", values: { string } }
	| { kind: "Optional", inner: SchemaDefinition }
	| { kind: "Struct", fields: { [string]: SchemaDefinition } }
	| { kind: "Array", element: SchemaDefinition, maxLength: number }
	| { kind: "Map", key: SchemaDefinition, value: SchemaDefinition, maxEntries: number }

-- Framework-private metadata for validation, structural diffing, and codecs.
-- Bounds must conservatively cover encoding; the codec owns the exact wire layout.
export type CompiledField = { read name: string, read schema: CompiledSchema }

export type CompiledSchema =
	{ kind: PrimitiveKind, maxEncodedBytes: number }
	| { kind: "String", maxBytes: number, maxEncodedBytes: number }
	| { kind: "Enum", values: { string }, ordinalsByValue: { [string]: number }, maxEncodedBytes: number }
	| { kind: "Optional", inner: CompiledSchema, maxEncodedBytes: number }
	| { kind: "Struct", fields: { CompiledField }, fieldsByName: { [string]: CompiledSchema }, maxEncodedBytes: number }
	| { kind: "Array", element: CompiledSchema, maxLength: number, maxEncodedBytes: number }
	| { kind: "Map", key: CompiledSchema, value: CompiledSchema, maxEntries: number, maxEncodedBytes: number }

export type Schema = {
	read Boolean: SchemaDefinition,
	read U8: SchemaDefinition,
	read U16: SchemaDefinition,
	read U32: SchemaDefinition,
	read I8: SchemaDefinition,
	read I16: SchemaDefinition,
	read I32: SchemaDefinition,
	read F32: SchemaDefinition,
	read F64: SchemaDefinition,
	read String: (maxBytes: number) -> SchemaDefinition,
	read Enum: (values: { string }) -> SchemaDefinition,
	read Optional: (inner: SchemaDefinition) -> SchemaDefinition,
	read Struct: (fields: { [string]: SchemaDefinition }) -> SchemaDefinition,
	read Array: (element: SchemaDefinition, maxLength: number) -> SchemaDefinition,
	read Map: (key: SchemaDefinition, value: SchemaDefinition, maxEntries: number) -> SchemaDefinition,
}

export type SchemaCompiler = {
	Compile: (definition: SchemaDefinition) -> (CompiledSchema?, string?),
}

export type SchemaValidator = {
	-- Erased value boundary; accepted values are constrained by the compiled schema.
	Validate: (schema: CompiledSchema, value: any) -> (boolean, string?),
}

-- Protocol bootstrap and transport
-- Private wire metadata, deliberately separate from server domain definitions.
export type ManifestEvent = { read id: string, read code: number, read payload: SchemaDefinition }

export type ManifestDomain = {
	read id: string,
	read code: number,
	read state: SchemaDefinition,
	read events: { ManifestEvent },
}

export type ManifestCommand = {
	read id: string,
	read code: number,
	read target: "None" | "Actor",
	read request: SchemaDefinition?,
	read result: SchemaDefinition?,
}

export type ProtocolManifest = {
	read version: number,
	read domains: { ManifestDomain },
	read commands: { ManifestCommand }?,
	read hints: { ManifestHint }?,
}

export type HintDirection = "ClientToServer" | "ServerToClient"
export type HintTarget = "None" | "Actor"
export type HintMode = "Latest" | "Pulse"

export type ManifestHint = {
	read id: string,
	read code: number,
	read direction: HintDirection,
	read target: HintTarget,
	read mode: HintMode,
	read payload: SchemaDefinition,
}

export type ClientHint = {
	read id: string,
	read code: number,
	read direction: HintDirection,
	read target: HintTarget,
	read mode: HintMode,
	read payloadCodec: CompiledCodec,
}

export type ClientEvent = { read id: string, read code: number, read codec: CompiledCodec }

export type ClientDomain = {
	read id: string,
	read code: number,
	read stateCodec: CompiledCodec,
	read eventsById: { [string]: ClientEvent },
	read eventsByCode: { [number]: ClientEvent },
}

export type ClientProtocol = {
	read domainsById: { [string]: ClientDomain },
	read domainsByCode: { [number]: ClientDomain },
	read commandsById: { [string]: ClientCommand }?,
	read commandsByCode: { [number]: ClientCommand }?,
	read hintsById: { [string]: ClientHint }?,
	read hintsByCode: { [number]: ClientHint }?,
}

export type HintRecord = { read hintCode: number, read targetHandle: number?, read sequence: number?, read payload: any? }
export type HintCursor = { source: buffer, offset: number, remaining: number }

export type HintCodec = {
	read EncodeRecord: (HintRecord) -> (buffer?, string?),
	read Pack: ({ buffer }) -> (buffer?, string?),
	read Open: (any) -> (HintCursor?, string?),
	read Read: (HintCursor) -> (HintRecord?, string?),
}

export type ClientCommand = {
	read id: string,
	read code: number,
	read target: "None" | "Actor",
	read requestCodec: CompiledCodec?,
	read resultCodec: CompiledCodec?,
}

export type CommandRequest = {
	read commandCode: number,
	read requestId: number,
	read targetHandle: number?,
	read request: any,
}

export type CommandResult = {
	read commandCode: number,
	read requestId: number,
	read status: "Accepted" | "Rejected" | "Unknown",
	read result: any,
	read reason: string?,
}

export type CommandCodec = {
	read EncodeRequest: (CommandRequest) -> (buffer?, string?),
	read DecodeRequest: (any) -> (CommandRequest?, string?),
	read EncodeResult: (CommandResult) -> (buffer?, string?),
	read DecodeResult: (any) -> (CommandResult?, string?),
}

export type CommandCodecModule = { Compile: (ClientProtocol) -> CommandCodec }

export type PreparedProtocol = {
	read manifest: ProtocolManifest,
	read bootstrapBuffer: buffer,
	read runtime: ClientProtocol,
}

-- Closed framework vocabulary; arbitrary diagnostic strings never enter Reject.
export type ProtocolRejectionReason =
	"ProtocolMismatch"
	| "MalformedPacket"
	| "UnsupportedSchema"
	| "BootstrapTooLarge"
	| "ReadyRejected"

export type ProtocolMessage =
	{ kind: "Hello", version: number }
	| { kind: "Bootstrap", manifest: ProtocolManifest }
	| { kind: "Ready" }
	| { kind: "ReadyAck" }
	| { kind: "Reject", reason: ProtocolRejectionReason }

export type ProtocolCodec = {
	Encode: (message: ProtocolMessage) -> (buffer?, string?),
	Decode: (payload: any) -> (ProtocolMessage?, string?),
}

export type ManifestCompiler = {
	Reconstruct: (manifest: ProtocolManifest) -> (ClientProtocol?, string?),
}

export type OwnedTransport = {
	root: Folder,
	reliable: RemoteEvent,
	unreliable: UnreliableRemoteEvent,
	Destroy: () -> (),
}

export type Transport = {
	ROOT_NAME: string,
	RELIABLE_NAME: string,
	UNRELIABLE_NAME: string,
	Create: (parent: Instance) -> (OwnedTransport?, string?),
	Locate: (parent: Instance) -> (OwnedTransport?, string?),
}

-- Actor stream
-- Framework-private logical records. No opcodes or byte widths are locked by these types.
export type ActorPatch =
	{ read kind: "Replace", read value: any }
	| { read kind: "Struct", read fields: { [string]: ActorPatch } }
	| { read kind: "Map", read entries: { [any]: any }, read removed: { any } }

export type ActorDomainTruth = { read value: any }
export type ActorDomainPatch = { read domainId: string, read patch: ActorPatch }
export type ActorEvent = { read domainId: string, read eventId: string, read payload: any }

export type ActorStreamRecord =
	-- Identity appears only when the connection first learns a handle. Replacement Begins omit it.
	{ kind: "BaselineBegin", handle: number, actorId: string?, generation: number, totalBytes: number }
	| { kind: "BaselineChunk", handle: number, generation: number, offset: number, bytes: buffer }
	| { kind: "BaselineEnd", handle: number, generation: number, revision: number }
	| { kind: "Commit", handle: number, revision: number, patches: { ActorDomainPatch }, events: { ActorEvent } }
	| { kind: "ActorRemove", handle: number }
	-- Terminal stream failure releases an assembly without removing Actor awareness.
	| { kind: "ActorHalt", handle: number }

export type ActorStreamCodec = {
	Encode: (records: { ActorStreamRecord }) -> (buffer?, string?),
	Measure: (records: { ActorStreamRecord }) -> (number?, string?),
	Decode: (payload: any) -> ({ ActorStreamRecord }?, string?),
	EncodeBaseline: (domains: { [string]: ActorDomainTruth }) -> (buffer?, string?),
	DecodeBaseline: (payload: buffer) -> ({ [string]: ActorDomainTruth }?, string?),
}

export type ActorSchemaCatalog = { [string]: CompiledSchema }

export type ActorStreamCodecModule = {
	Compile: (protocol: ClientProtocol, schemas: ActorSchemaCatalog) -> ActorStreamCodec,
}

-- Private diagnostics: counters saturate at the largest exact integer. Gauges
-- include staged ownership until its existing owner releases it.
-- Transport counters count calls before handoff (including failed calls), not
-- delivery. Bytes are KRF buffer lengths, never platform wire bandwidth.
-- Logical records: Actor envelopes, command request/results and resync; bootstrap
-- control messages contribute sends/bytes but zero logical records.
-- Work counters count admission calls/charges, not authoritative outcomes.
-- Server/Connection: commandRequests/Bytes are admitted request ownership;
-- reliableRecords are ledger charges, DeliveryBytes sum their accounting weights.
-- Server only: RetainedBytes deduplicates shared ledger payload accounting;
-- connections counts tracked transport lifetimes, including pre-Ready/rejected.
-- Both sides: hintSend* counts encoded records/bytes excluding packet envelopes;
-- hintReceive* counts owned complete wire packets/bytes including envelopes.
-- Refused Hint work counts local admission drops, not later stale/transport loss.
-- Scope-inapplicable fields stay zero; this is a private foundation inventory,
-- not a promise that all Networking ownership or outcomes are instrumented.
export type DiagnosticScope = "Server" | "Connection" | "Client"

export type DiagnosticCounter =
	"reliableSendAttempts"
	| "reliableEncodedBytes"
	| "reliableLogicalRecords"
	| "unreliableSendAttempts"
	| "unreliableEncodedBytes"
	| "unreliableLogicalRecords"
	| "commandsAdmitted"
	| "commandsRefused"
	| "hintRecordsAdmitted"
	| "hintRecordsRefused"
	| "hintPacketsAdmitted"
	| "hintPacketsRefused"
	| "reliableChargesAdmitted"
	| "reliableChargesRefused"

export type DiagnosticGauge =
	"connections"
	| "reliableRecords"
	| "reliableRetainedBytes"
	| "reliableDeliveryBytes"
	| "commandRequests"
	| "commandBytes"
	| "hintSendRecords"
	| "hintSendBytes"
	| "hintReceivePackets"
	| "hintReceiveBytes"

export type DiagnosticGaugeSnapshot = { read current: number, read highWater: number }

export type DiagnosticSnapshot = {
	read scope: DiagnosticScope,
	read counters: {
		read reliableSendAttempts: number,
		read reliableEncodedBytes: number,
		read reliableLogicalRecords: number,
		read unreliableSendAttempts: number,
		read unreliableEncodedBytes: number,
		read unreliableLogicalRecords: number,
		read commandsAdmitted: number,
		read commandsRefused: number,
		read hintRecordsAdmitted: number,
		read hintRecordsRefused: number,
		read hintPacketsAdmitted: number,
		read hintPacketsRefused: number,
		read reliableChargesAdmitted: number,
		read reliableChargesRefused: number,
	},
	read gauges: {
		read connections: DiagnosticGaugeSnapshot,
		read reliableRecords: DiagnosticGaugeSnapshot,
		read reliableRetainedBytes: DiagnosticGaugeSnapshot,
		read reliableDeliveryBytes: DiagnosticGaugeSnapshot,
		read commandRequests: DiagnosticGaugeSnapshot,
		read commandBytes: DiagnosticGaugeSnapshot,
		read hintSendRecords: DiagnosticGaugeSnapshot,
		read hintSendBytes: DiagnosticGaugeSnapshot,
		read hintReceivePackets: DiagnosticGaugeSnapshot,
		read hintReceiveBytes: DiagnosticGaugeSnapshot,
	},
}

export type DiagnosticCollector = {
	Count: (self: DiagnosticCollector, DiagnosticCounter, number) -> (),
	Adjust: (self: DiagnosticCollector, DiagnosticGauge, number) -> (),
	Snapshot: (self: DiagnosticCollector) -> DiagnosticSnapshot,
}

return types
