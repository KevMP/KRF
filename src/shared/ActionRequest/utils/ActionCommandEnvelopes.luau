--!strict
-- The outer N9 contracts of the three fixed Action commands. The server publishes
-- exactly these envelopes and the client verifies the reconstructed protocol
-- against them, so a correctly named but differently shaped command never starts.
local NetworkingTypes = require(script.Parent.Parent.Parent.Networking.types)
local Schema: NetworkingTypes.Schema = require(script.Parent.Parent.Parent.Networking.Schema)
local Constants = require(script.Parent.ActionRequestConstants)

export type ActionCommandEnvelope = {
	read id: string,
	read target: "None" | "Actor",
	read request: NetworkingTypes.SchemaDefinition,
	read result: NetworkingTypes.SchemaDefinition?,
	-- Follow-ups use N9's bounded protected admission reserve.
	read followUp: boolean,
}

local start: ActionCommandEnvelope = table.freeze({
	id = Constants.START_COMMAND_ID,
	target = "Actor" :: "Actor",
	request = Schema.Struct({
		actionId = Schema.String(Constants.MAX_ACTION_ID_BYTES),
		contractTag = Schema.U32,
		payload = Schema.String(Constants.MAX_PAYLOAD_BYTES),
	}),
	result = Schema.Struct({ sequenceId = Schema.U32 }),
	followUp = false,
})

local stop: ActionCommandEnvelope = table.freeze({
	id = Constants.STOP_COMMAND_ID,
	target = "None" :: "None",
	request = Schema.Struct({
		originalStartRequestId = Schema.U32,
		payload = Schema.String(Constants.MAX_PAYLOAD_BYTES),
	}),
	followUp = true,
})

local interrupt: ActionCommandEnvelope = table.freeze({
	id = Constants.INTERRUPT_COMMAND_ID,
	target = "None" :: "None",
	request = Schema.Struct({
		originalStartRequestId = Schema.U32,
		reason = Schema.Enum(table.clone(Constants.INTERRUPT_REASONS)),
	}),
	followUp = true,
})

return table.freeze({
	Start = start,
	Stop = stop,
	Interrupt = interrupt,
	All = table.freeze({ start, stop, interrupt }),
})
