--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local PublicTypes = require(KRF.client.Actor.types)
local SharedTypes = require(KRF.shared.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)

-- The public facade path is specified by #79. Server module locations are not;
-- find the named contracts without prescribing a new source-system layout.
local registryModule: Instance? = KRF.server:FindFirstChild("CommandRegistry", true)
local runtimeModule: Instance? = KRF.client.Networking:FindFirstChild("CommandRuntime")
-- Absent modules must not produce analyzer/import failures on a RED branch.
-- Existing modules still load normally; a broken import is a fixture regression.
local requireOptional: (ModuleScript) -> any = require :: any
local registry: any = if registryModule ~= nil then requireOptional(registryModule :: ModuleScript) else nil

local runtime: any = if runtimeModule ~= nil then requireOptional(runtimeModule :: ModuleScript) else nil

-- Test input contracts mirror #79 until production owns the N9 types. Any is
-- limited to schema-erased data and deliberately invalid inputs at the boundary.
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
	assert(registry ~= nil, "[N9 missing contract] CommandRegistry: immutable Server.Init command catalog (#79.1)")

	return registry
end

function TestUtils.runtime(): Facade
	assert(runtime ~= nil, "[N9 missing contract] client.Networking.CommandRuntime: Send and runtime events (#79.21)")

	return runtime
end

return TestUtils
