--!strict
local Types = require(script.Parent.Parent.types)
local NetworkingTypes = require(script.Parent.Parent.Parent.Networking.types)

-- I5 TDD scaffold. Canonical schema serialization and the deterministic U32 hash remain unimplemented.
local ActionContractTag: Types.ActionContractTagModule = table.freeze({
	Compute = function(
		_actionId: string,
		_start: NetworkingTypes.CompiledSchema?,
		_stop: Types.CompiledActionPayload?,
		_allowInputInterrupt: boolean,
		_requiresClientRelease: boolean,
		_onDisconnect: Types.ActionDisconnectPolicy
	): number
		return 0
	end,
})

return ActionContractTag
