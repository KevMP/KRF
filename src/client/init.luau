--!strict
local ClientTypes = require(script.types)

export type StartupFailure = ClientTypes.StartupFailure

local Client = {} :: ClientTypes.Client

function Client.Init(): (boolean, StartupFailure?)
	return false, { system = "Networking", reason = "N2NotImplemented" }
end

function Client._IsInitialized(): boolean
	return false
end

function Client._SetDependenciesForTests(_dependencies: ClientTypes.Dependencies): () end

function Client._ResetForTests(): () end

return Client
