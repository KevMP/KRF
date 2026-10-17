--!strict
local PublicTypes = require(script.Parent.Parent.Actor.types)
local StreamTypes = require(script.Parent.ActorStreamTypes)
local ProtocolTypes = require(script.Parent.Parent.Parent.shared.Networking.ProtocolTypes)
local WireTypes = require(script.Parent.Parent.Parent.shared.Networking.ActorStreamTypes)

local types = {}
export type Fault = { actorId: string, reason: string }
export type Options = { SendReliable: (buffer) -> (), ReportFault: (Fault) -> () }
-- Private diagnostics, never reachable through ActorView or its public registry.
export type Diagnostics = {
	revision: number?,
	status: "Live" | "AwaitingBaseline" | "Halted",
	bufferedCommitCount: number,
}
export type Runtime = {
	read consumer: StreamTypes.Consumer,
	read registry: PublicTypes.ActorViewRegistry,
	_InspectForTests: (self: Runtime, handle: number) -> Diagnostics?,
	Destroy: (self: Runtime) -> (),
}
export type RuntimeModule = {
	new: (ProtocolTypes.ClientProtocol, WireTypes.SchemaCatalog, Options) -> Runtime,
}
return types
