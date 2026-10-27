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

-- Private local diagnostics. Scope-inapplicable observations stay zero/nil.
-- Counters are monotonic, saturating at 2^53-1. Gauges expose current ownership
-- and simultaneous high-water; maxima are observed per-pump work or seconds.
-- Snapshot ages are current local-clock samples on demand, never wire RTT.
--
-- Transport attempts/bytes are counted before handoff, even if a call fails;
-- bytes are KRF buffer lengths, not Roblox framing/compression/wire bandwidth.
-- Logical records count Actor/Hint envelopes, command requests/results and resync;
-- bootstrap/control handshakes contribute sends/bytes but zero logical records.
-- HintsSent counts records after a nonthrowing/nonyielding local send callback;
-- HintsReceived counts validated, target-resolved/authorized semantic callback
-- entry. Neither proves remote delivery or game callback success. Callback/send
-- failures are separate. Coalesced samples are not counted as drops. Stale and
-- unauthorized are subsets of record drops; malformed counts packet detections.
-- Whole packet refusals are counted in packet units without decoding for stats;
-- discarded admitted tails also count their bounded framed-record candidates.
--
-- Server commands: Received/Admitted/Dispatched are distinct from Executed
-- (author handler entry); Accepted/Rejected are schema-valid local outcomes.
-- Uncertain means local Unknown/cancelled dispatch. Faulted counts each affected dispatch once;
-- these counters are not mutually exclusive final delivery classifications.
-- Client commands: admission retains correlation metadata; result receipt is
-- correlated decoding, and outcome counters count public notification entry.
-- Unknown notifies once while metadata remains for a late definitive result.
-- A late Accepted/Rejected can therefore follow Uncertain without decrementing it.
-- Reservations/fenced/history bytes are the existing capacity accounting weights.
--
-- Publication admissions/refusals count visible recipient Enqueue calls; barriers
-- count eventful commits, not individual events. Coalesces absorb an unsent state
-- tail. Abandoned records count stored entries discarded without incremental send.
-- Captured baselines are admitted N4 canonical anchors; Restarted counts every
-- later admitted generation, not only thrashing. Completed is matching local End
-- handoff; Abandoned is invalidation before completion, including owner close.
-- Recovery backoffs count new retry waits, not idle inspections. Abandonment is
-- cancellation/exhaustion of a live retry chain/episode; successful truth resets
-- it without abandonment. Server resync counts ingress; client counts local
-- recovery opportunities, including duplicate starts and admission refusals.
--
-- ReliableRecords/DeliveryBytes include staged ledger charges until release;
-- server RetainedBytes deduplicates shared payload accounting (not heap).
-- PublicationQueued* excludes drained/staged records, whose ledger charge stays.
-- AwareStreams counts live awareness mappings; reliableActiveStreams includes
-- ordered pending/staged work; reliableActiveConnections includes that work or
-- result reservations. Connections includes pre-Ready/rejected transport scopes;
-- ReadyConnections counts installed Ready awareness owners.
-- Hint send bytes exclude envelopes, receive bytes include them. Latest keys
-- count bounded sequence indexes independently of optional queued samples.
-- ClientBaselineBytes counts active assembly body + occupied bitmap, excluding
-- decoder temporaries/installed views; clientCommandMetadataBytes is budget
-- weight, not encoded bytes. Deferred reliable bytes are queued full buffers.
--
-- Reliable pump work is the sum of existing nine budget claims; command work is
-- connection visits + dispatches; Hint work is attempted record inspections.
-- Per-connection maxima expose the applicable subset. Unproductive inspection
-- means no record staged/dispatched or no completed receive callback, not zero CPU.
-- Residence maxima sample local dequeue/discard (baseline generations through
-- local completion/abandonment). Eligible reliable age excludes retry backoff,
-- unfilled results and causally blocked work; it ignores transient pump quotas.
-- Only explicit snapshot reads walk bounded live queues to sample current ages.
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
	| "publicationAdmitted"
	| "publicationDropped"
	| "stateCoalesces"
	| "semanticBarriers"
	| "streamDiscontinuities"
	| "baselinesCaptured"
	| "baselinesCompleted"
	| "baselinesRestarted"
	| "baselinesAbandoned"
	| "recoveryBackoffs"
	| "recoveryAbandoned"
	| "resyncRequests"
	| "resyncAdmitted"
	| "resyncDeduplicated"
	| "resyncRateLimited"
	| "resyncRefused"
	| "commandsAbandoned"
	| "commandsReceived"
	| "commandsDispatched"
	| "commandsExecuted"
	| "commandsAccepted"
	| "commandsRejected"
	| "commandsRateLimited"
	| "commandsFaulted"
	| "commandsUncertain"
	| "commandResultsExpired"
	| "commandReservationsAdmitted"
	| "commandReservationsRefused"
	| "hintsSent"
	| "hintsReceived"
	| "hintsCoalesced"
	| "hintsDropped"
	| "hintsStaleDropped"
	| "hintsMalformed"
	| "hintsUnauthorized"
	| "hintPacketsDropped"
	| "hintCallbackFaults"
	| "hintSendFailures"
	| "reliableConnectionVisits"
	| "reliableStreamVisits"
	| "reliableChecks"
	| "reliablePrepares"
	| "reliableMeasurements"
	| "reliableEncodes"
	| "reliableCaptures"
	| "reliablePriorityVisits"
	| "reliableUnproductiveInspections"
	| "commandConnectionVisits"
	| "commandUnproductiveInspections"
	| "hintConnectionVisits"
	| "hintSendVisits"
	| "hintReceiveVisits"
	| "hintUnproductiveInspections"
	| "publicationRecordsAbandoned"
	| "baselineCapacityRefusals"
	| "commandResultsReceived"
	| "clientReliableDeferredAdmitted"
	| "clientReliableDeferredDropped"

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
	| "readyConnections"
	| "awareStreams"
	| "reliableActiveConnections"
	| "reliableActiveStreams"
	| "baselineGenerations"
	| "recoveryStreams"
	| "commandResultSlots"
	| "commandResultReservedBytes"
	| "commandFencedRecords"
	| "commandFencedBytes"
	| "commandHistoryEntries"
	| "commandHistoryBytes"
	| "clientCommandPending"
	| "clientCommandMetadataBytes"
	| "clientBaselineAssemblies"
	| "clientBaselineBytes"
	| "hintLatestKeys"
	| "publicationQueuedRecords"
	| "publicationQueuedBytes"
	| "clientReliableDeferredRecords"
	| "clientReliableDeferredBytes"

export type DiagnosticMaximum =
	"reliablePumpWorkUnits"
	| "commandPumpWorkUnits"
	| "hintSendPumpWorkUnits"
	| "hintReceivePumpWorkUnits"
	| "commandQueueResidenceSeconds"
	| "reliableQueueResidenceSeconds"
	| "hintSendQueueResidenceSeconds"
	| "hintReceiveQueueResidenceSeconds"

export type DiagnosticAge =
	"reliableEligibleQueueAgeSeconds"
	| "commandQueueAgeSeconds"
	| "hintSendQueueAgeSeconds"
	| "hintReceiveQueueAgeSeconds"

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
		read publicationAdmitted: number,
		read publicationDropped: number,
		read stateCoalesces: number,
		read semanticBarriers: number,
		read streamDiscontinuities: number,
		read baselinesCaptured: number,
		read baselinesCompleted: number,
		read baselinesRestarted: number,
		read baselinesAbandoned: number,
		read recoveryBackoffs: number,
		read recoveryAbandoned: number,
		read resyncRequests: number,
		read resyncAdmitted: number,
		read resyncDeduplicated: number,
		read resyncRateLimited: number,
		read resyncRefused: number,
		read commandsAbandoned: number,
		read commandsReceived: number,
		read commandsDispatched: number,
		read commandsExecuted: number,
		read commandsAccepted: number,
		read commandsRejected: number,
		read commandsRateLimited: number,
		read commandsFaulted: number,
		read commandsUncertain: number,
		read commandResultsExpired: number,
		read commandReservationsAdmitted: number,
		read commandReservationsRefused: number,
		read hintsSent: number,
		read hintsReceived: number,
		read hintsCoalesced: number,
		read hintsDropped: number,
		read hintsStaleDropped: number,
		read hintsMalformed: number,
		read hintsUnauthorized: number,
		read hintPacketsDropped: number,
		read hintCallbackFaults: number,
		read hintSendFailures: number,
		read reliableConnectionVisits: number,
		read reliableStreamVisits: number,
		read reliableChecks: number,
		read reliablePrepares: number,
		read reliableMeasurements: number,
		read reliableEncodes: number,
		read reliableCaptures: number,
		read reliablePriorityVisits: number,
		read reliableUnproductiveInspections: number,
		read commandConnectionVisits: number,
		read commandUnproductiveInspections: number,
		read hintConnectionVisits: number,
		read hintSendVisits: number,
		read hintReceiveVisits: number,
		read hintUnproductiveInspections: number,
		read publicationRecordsAbandoned: number,
		read baselineCapacityRefusals: number,
		read commandResultsReceived: number,
		read clientReliableDeferredAdmitted: number,
		read clientReliableDeferredDropped: number,
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
		read readyConnections: DiagnosticGaugeSnapshot,
		read awareStreams: DiagnosticGaugeSnapshot,
		read reliableActiveConnections: DiagnosticGaugeSnapshot,
		read reliableActiveStreams: DiagnosticGaugeSnapshot,
		read baselineGenerations: DiagnosticGaugeSnapshot,
		read recoveryStreams: DiagnosticGaugeSnapshot,
		read commandResultSlots: DiagnosticGaugeSnapshot,
		read commandResultReservedBytes: DiagnosticGaugeSnapshot,
		read commandFencedRecords: DiagnosticGaugeSnapshot,
		read commandFencedBytes: DiagnosticGaugeSnapshot,
		read commandHistoryEntries: DiagnosticGaugeSnapshot,
		read commandHistoryBytes: DiagnosticGaugeSnapshot,
		read clientCommandPending: DiagnosticGaugeSnapshot,
		read clientCommandMetadataBytes: DiagnosticGaugeSnapshot,
		read clientBaselineAssemblies: DiagnosticGaugeSnapshot,
		read clientBaselineBytes: DiagnosticGaugeSnapshot,
		read hintLatestKeys: DiagnosticGaugeSnapshot,
		read publicationQueuedRecords: DiagnosticGaugeSnapshot,
		read publicationQueuedBytes: DiagnosticGaugeSnapshot,
		read clientReliableDeferredRecords: DiagnosticGaugeSnapshot,
		read clientReliableDeferredBytes: DiagnosticGaugeSnapshot,
	},
	read maxima: {
		read reliablePumpWorkUnits: number,
		read commandPumpWorkUnits: number,
		read hintSendPumpWorkUnits: number,
		read hintReceivePumpWorkUnits: number,
		read commandQueueResidenceSeconds: number,
		read reliableQueueResidenceSeconds: number,
		read hintSendQueueResidenceSeconds: number,
		read hintReceiveQueueResidenceSeconds: number,
	},
	read ages: {
		read reliableEligibleQueueAgeSeconds: number?,
		read commandQueueAgeSeconds: number?,
		read hintSendQueueAgeSeconds: number?,
		read hintReceiveQueueAgeSeconds: number?,
	},
}

-- Fixed process-lifetime categories: never key suppression by Player, Actor or error text.
export type DiagnosticWarning =
	"MalformedTraffic"
	| "CommandOverload"
	| "ResyncAbuse"
	| "HintAbuse"
	| "BaselineRecovery"
	| "CommandFault"
	| "TransportFault"
	| "ObserverFault"
	| "ActorStreamFault"

export type DiagnosticWarningOptions = {
	Now: (() -> number)?,
	windowSeconds: number?,
	maxPerWindow: number?,
	Emit: ((DiagnosticWarning, string?, number) -> ())?,
}

export type DiagnosticCollector = {
	Warn: (self: DiagnosticCollector, DiagnosticWarning, string?) -> (),
	Count: (self: DiagnosticCollector, DiagnosticCounter, number) -> (),
	Adjust: (self: DiagnosticCollector, DiagnosticGauge, number) -> (),
	Set: (self: DiagnosticCollector, DiagnosticGauge, number) -> number,
	GetCurrent: (self: DiagnosticCollector, DiagnosticGauge) -> number,
	Observe: (self: DiagnosticCollector, DiagnosticMaximum, number) -> (),
	SetAgeSource: (self: DiagnosticCollector, DiagnosticAge, (() -> number?)?) -> (),
	GetAge: (self: DiagnosticCollector, DiagnosticAge) -> number?,
	ClearSources: (self: DiagnosticCollector) -> (),
	Snapshot: (self: DiagnosticCollector) -> DiagnosticSnapshot,
}

return types
