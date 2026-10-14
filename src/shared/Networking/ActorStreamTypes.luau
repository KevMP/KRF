--!strict
local ProtocolTypes = require(script.Parent.ProtocolTypes)
local SchemaTypes = require(script.Parent.types)

local types = {}

-- N4 private logical records. No opcodes or byte widths are locked by these types.
export type Patch =
	{ read kind: "Replace", read value: any }
	| { read kind: "Struct", read fields: { [string]: Patch } }
	| { read kind: "Map", read entries: { [any]: any }, read removed: { any } }
export type DomainTruth = { read value: any }
export type DomainPatch = { read domainId: string, read patch: Patch }
export type Event = { read domainId: string, read eventId: string, read payload: any }
export type Record =
	-- Identity appears only when the connection first learns a handle. Replacement Begins omit it.
	{ kind: "BaselineBegin", handle: number, actorId: string?, generation: number, totalBytes: number }
	| { kind: "BaselineChunk", handle: number, generation: number, offset: number, bytes: buffer }
	| { kind: "BaselineEnd", handle: number, generation: number, revision: number }
	| { kind: "Commit", handle: number, revision: number, patches: { DomainPatch }, events: { Event } }
	| { kind: "ActorRemove", handle: number }
export type Codec = {
	Encode: (records: { Record }) -> (buffer?, string?),
	Measure: (records: { Record }) -> (number?, string?),
	Decode: (payload: any) -> ({ Record }?, string?),
	EncodeBaseline: (domains: { [string]: DomainTruth }) -> (buffer?, string?),
	DecodeBaseline: (payload: buffer) -> ({ [string]: DomainTruth }?, string?),
}
export type SchemaCatalog = { [string]: SchemaTypes.CompiledSchema }
export type CodecModule = { Compile: (protocol: ProtocolTypes.ClientProtocol, schemas: SchemaCatalog) -> Codec }

return types
