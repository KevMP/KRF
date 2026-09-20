--!strict

local ServerStartTypes = require(script.types)

export type ServerStartConfig = ServerStartTypes.ServerStartConfig
export type StartupFailure = ServerStartTypes.StartupFailure

local Server = {}

function Server.Init(_config: ServerStartConfig): (boolean, StartupFailure?)
	return false, {
		system = "Server",
		reason = "ServerInitNotImplemented",
	}
end

function Server._ResetForTests(): () end

return Server
