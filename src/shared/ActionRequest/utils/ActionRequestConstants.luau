--!strict
-- Private wire bounds for the three fixed Action request commands.
return table.freeze({
	START_COMMAND_ID = "KRF.Action.Start",
	STOP_COMMAND_ID = "KRF.Action.Stop",
	INTERRUPT_COMMAND_ID = "KRF.Action.Interrupt",
	MAX_ACTION_ID_BYTES = 96,
	MAX_PAYLOAD_BYTES = 8192,
	INTERRUPT_REASONS = table.freeze({
		"RouteInvalidated",
		"ContextDisabled",
		"ActorSwitched",
		"FocusLost",
		"StopPreparationFailed",
		"ClientShutdown",
	}),
})
