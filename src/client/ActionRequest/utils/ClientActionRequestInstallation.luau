--!strict
local Types = require(script.Parent.Parent.types)
local NetworkingTypes = require(script.Parent.Parent.Parent.Networking.types)
local ActionRequestTypes = require(script.Parent.Parent.Parent.Parent.shared.ActionRequest.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.ActionRequest.utils.ActionRequestConstants)
local CommandState = require(script.Parent.Parent.Parent.Networking.utils.CommandRuntimeState)
local Runtime = require(script.Parent.Parent.ClientActionRequestRuntime)
local State = require(script.Parent.ClientActionRequestState)

local FIXED_COMMANDS: { [string]: "None" | "Actor" } = {
	[Constants.START_COMMAND_ID] = "Actor",
	[Constants.STOP_COMMAND_ID] = "None",
	[Constants.INTERRUPT_COMMAND_ID] = "None",
}

table.freeze(FIXED_COMMANDS)

-- Each READY installation is a new incarnation so I6 never confuses admissions across reconnects.
local incarnations: number = 0
local Installation = {}

-- Runs after the command runtime is installed and before READY. A client configured with
-- request schemas requires the server to publish all three fixed commands.
function Installation.Install(
	catalog: ActionRequestTypes.ActionRequestCatalog,
	protocol: SharedNetworkingTypes.ClientProtocol
): ((() -> ())?, string?)
	local commandsById: { [string]: SharedNetworkingTypes.ClientCommand } = protocol.commandsById or {}

	for commandId: string, target: "None" | "Actor" in FIXED_COMMANDS do
		local command: SharedNetworkingTypes.ClientCommand? = commandsById[commandId]

		if command == nil or command.target ~= target then
			return nil, "ActionRequestCommandsUnavailable"
		end
	end

	local commands: NetworkingTypes.ClientCommandRuntime? = CommandState.Get()

	if commands == nil then
		return nil, "ActionRequestCommandsUnavailable"
	end

	local runtimeCommands: NetworkingTypes.ClientCommandRuntime = commands
	incarnations += 1

	local port: Types.ActionRequestCommandPort = table.freeze({
		SendAdmitted = function(commandId, actor, request, admit): (number?, string?)
			return runtimeCommands:_SendAdmitted(commandId, actor, request, admit)
		end,
		ObserveOutcomes = function(observer: (NetworkingTypes.CommandResult) -> ()): () -> ()
			return runtimeCommands:_ObserveOutcomes(observer)
		end,
	})

	local installed: Types.ClientActionRequestRuntime =
		Runtime.new(catalog, { commands = port, incarnation = incarnations })

	State.Install(installed)
	local active: boolean = true

	return function(): ()
		if not active then
			return
		end

		active = false

		if State.Get() == installed then
			State.Install(nil)
		end

		installed:Destroy()
	end,
		nil
end

return Installation
