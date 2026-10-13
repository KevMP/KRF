--!strict
local NetworkingTypes = require(script.Parent.types)

local types = {}

-- Private wire metadata, deliberately separate from server domain definitions.
export type ManifestEvent = { read id: string, read code: number, read payload: NetworkingTypes.SchemaDefinition }
export type ManifestDomain = {
	read id: string,
	read code: number,
	read state: NetworkingTypes.SchemaDefinition,
	read events: { ManifestEvent },
}
export type ProtocolManifest = { read version: number, read domains: { ManifestDomain } }
export type ClientEvent = { read id: string, read code: number, read codec: NetworkingTypes.CompiledCodec }
export type ClientDomain = {
	read id: string,
	read code: number,
	read stateCodec: NetworkingTypes.CompiledCodec,
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
export type RejectionReason =
	"ProtocolMismatch"
	| "MalformedPacket"
	| "UnsupportedSchema"
	| "BootstrapTooLarge"
	| "ReadyRejected"
export type Message =
	{ kind: "Hello", version: number }
	| { kind: "Bootstrap", manifest: ProtocolManifest }
	| { kind: "Ready" }
	| { kind: "ReadyAck" }
	| { kind: "Reject", reason: RejectionReason }
export type ProtocolCodec = {
	Encode: (message: Message) -> (buffer?, string?),
	Decode: (payload: any) -> (Message?, string?),
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

return types
