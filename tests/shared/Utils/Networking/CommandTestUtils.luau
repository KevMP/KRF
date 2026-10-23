--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local PublicTypes = require(KRF.client.Actor.types)
local SharedTypes = require(KRF.shared.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)

local registry = require(KRF.server.Networking.CommandRegistry)
local runtime = require(KRF.client.Networking.CommandRuntime)

-- Boundary fixtures retain deliberately invalid target modes and schema-erased data.
export type Definition = {
	id: string,
	target: string,
	request: SharedTypes.SchemaDefinition?,
	result: SharedTypes.SchemaDefinition?,
	authorize: (context: any, request: any) -> (boolean, string?),
	handle: (context: any, request: any) -> any,
}

export type Registry = {
	IsLoaded: () -> boolean,
	Get: (string) -> any,
	GetAll: () -> { any },
}

export type Facade = {
	read Send: (string, PublicTypes.ActorView?, any?) -> (number?, string?),
	read OnCommandResult: SignalTypes.Event<any>,
	read OnCommandUncertain: SignalTypes.Event<any>,
}

export type ManifestCommand = {
	id: string,
	code: number,
	target: string,
	request: SharedTypes.SchemaDefinition?,
	result: SharedTypes.SchemaDefinition?,
}

export type Manifest = SharedTypes.ProtocolManifest & { commands: { ManifestCommand } }

export type ClientCommand = {
	id: string,
	code: number,
	target: string,
	requestCodec: SharedTypes.CompiledCodec?,
	resultCodec: SharedTypes.CompiledCodec?,
}

export type Protocol = SharedTypes.ClientProtocol & {
	commandsById: { [string]: ClientCommand },
	commandsByCode: { [number]: ClientCommand },
}

export type TargetResolver = {
	ResolveActor: (self: any, player: Player, handle: number) -> (ActorTypes.Actor?, string?),
}

local TestUtils = {}

function TestUtils.definition(id: string, target: string?): Definition
	return {
		id = id,
		target = target or "None",
		authorize = function(_context: any, _request: any): (boolean, string?)
			return true, nil
		end,
		handle = function(_context: any, _request: any): any
			return { accepted = true }
		end,
	}
end

function TestUtils.registry(): Registry
	return registry
end

function TestUtils.runtime(): Facade
	return runtime
end

return TestUtils
