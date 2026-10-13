--!strict
local NetworkingTypes = require(script.Parent.types)

local types = {}

-- Private wire metadata, deliberately separate from server domain definitions.
export type ManifestEvent = { id: string, code: number, payload: NetworkingTypes.SchemaDefinition }
export type ManifestDomain = {
	id: string,
	code: number,
	state: NetworkingTypes.SchemaDefinition,
	events: { ManifestEvent },
}
export type ProtocolManifest = { version: number, domains: { ManifestDomain } }
export type ClientEvent = { id: string, code: number, codec: NetworkingTypes.CompiledCodec }
export type ClientDomain = {
	id: string,
	code: number,
	stateCodec: NetworkingTypes.CompiledCodec,
	eventsById: { [string]: ClientEvent },
	eventsByCode: { [number]: ClientEvent },
}
export type ClientProtocol = {
	domainsById: { [string]: ClientDomain },
	domainsByCode: { [number]: ClientDomain },
}
export type PreparedProtocol = {
	manifest: ProtocolManifest,
	bootstrapBuffer: buffer,
	runtime: ClientProtocol,
}
export type Message =
	{ kind: "Hello", version: number }
	| { kind: "Bootstrap", manifest: ProtocolManifest }
	| { kind: "Ready" }
	| { kind: "ReadyAck" }
	| { kind: "Reject", reason: string }
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
