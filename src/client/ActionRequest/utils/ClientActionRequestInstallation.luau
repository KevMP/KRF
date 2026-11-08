--!strict
local Types = require(script.Parent.Parent.types)
local NetworkingTypes = require(script.Parent.Parent.Parent.Networking.types)
local ActionRequestTypes = require(script.Parent.Parent.Parent.Parent.shared.ActionRequest.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local SchemaCompiler = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.SchemaCompiler)
local ContractTag = require(script.Parent.Parent.Parent.Parent.shared.ActionRequest.utils.ActionContractTag)
local Envelopes = require(script.Parent.Parent.Parent.Parent.shared.ActionRequest.utils.ActionCommandEnvelopes)
local CommandState = require(script.Parent.Parent.Parent.Networking.utils.CommandRuntimeState)
local Runtime = require(script.Parent.Parent.ClientActionRequestRuntime)
local State = require(script.Parent.ClientActionRequestState)

-- Canonical descriptions of the fixed outer contracts the server must publish.
type ExpectedCommand = {
	envelope: Envelopes.ActionCommandEnvelope,
	request: string,
	result: string,
}

local function describe(definition: SharedNetworkingTypes.SchemaDefinition?): string
	if definition == nil then
		return ContractTag.Describe(nil)
	end

	local compiled: SharedNetworkingTypes.CompiledSchema?, reason: string? = SchemaCompiler.Compile(definition)
	assert(compiled ~= nil, reason)

	return ContractTag.Describe(compiled)
end

local EXPECTED_COMMANDS: { ExpectedCommand } = {}
local FOLLOW_UP_COMMAND_IDS: { string } = {}

for _, envelope: Envelopes.ActionCommandEnvelope in Envelopes.All do
	table.insert(EXPECTED_COMMANDS, {
		envelope = envelope,
		request = describe(envelope.request),
		result = describe(envelope.result),
	})

	if envelope.followUp then
		table.insert(FOLLOW_UP_COMMAND_IDS, envelope.id)
	end
end

table.freeze(EXPECTED_COMMANDS)
table.freeze(FOLLOW_UP_COMMAND_IDS)

-- Each READY installation is a new incarnation so I6 never confuses admissions across reconnects.
local incarnations: number = 0
local Installation = {}

-- Runs after the command runtime is installed and before READY. A client configured with
-- request schemas requires the server to publish all three fixed commands with exactly the
-- shared outer contracts, so an incompatible protocol fails startup rather than each send.
function Installation.Install(
	catalog: ActionRequestTypes.ActionRequestCatalog,
	protocol: SharedNetworkingTypes.ClientProtocol
): ((() -> ())?, string?)
	local commandsById: { [string]: SharedNetworkingTypes.ClientCommand } = protocol.commandsById or {}

	for _, expected: ExpectedCommand in EXPECTED_COMMANDS do
		local command: SharedNetworkingTypes.ClientCommand? = commandsById[expected.envelope.id]

		if command == nil or command.target ~= expected.envelope.target then
			return nil, "ActionRequestCommandsUnavailable"
		elseif
			ContractTag.Describe(command.requestSchema) ~= expected.request
			or ContractTag.Describe(command.resultSchema) ~= expected.result
		then
			return nil, "ActionRequestCommandsIncompatible"
		end
	end

	local commands: NetworkingTypes.ClientCommandRuntime? = CommandState.Get()

	if commands == nil then
		return nil, "ActionRequestCommandsUnavailable"
	end

	local runtimeCommands: NetworkingTypes.ClientCommandRuntime = commands
	local classified: boolean = runtimeCommands:_ClassifyFollowUps(FOLLOW_UP_COMMAND_IDS)

	if not classified then
		return nil, "ActionRequestCommandsUnavailable"
	end

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
		runtimeCommands:_ClassifyFollowUps({})
	end,
		nil
end

return Installation
