--!strict
local types = {}

-- Schemas and codecs
-- Framework-private N2 codec contract. Read limits are exclusive byte offsets.
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

-- Framework-private metadata for validation, structural diffing, and N2 codecs.
-- Bounds must conservatively cover encoding; N2 owns the exact wire layout.
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

export type ProtocolManifest = { read version: number, read domains: { ManifestDomain } }
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
}

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
-- N4 private logical records. No opcodes or byte widths are locked by these types.
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

return types
