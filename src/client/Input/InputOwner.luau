--!strict
local Types = require(script.Parent.types)

local InputOwner = {}

function InputOwner.new(options: Types.InputOwnerOptions): Types.InputOwner
	local destroyed: boolean = false

	local function unavailable(): string
		return if destroyed or not options.IsReady() then "ClientNotReady" else "InputNotImplemented"
	end

	local function reject(): (boolean, string?)
		return false, unavailable()
	end

	local function noSnapshot(): nil
		return nil
	end

	local function disconnect(): () end

	return {
		SetSource = reject,
		RemoveSource = reject,
		SetContextEnabled = reject,
		GetInput = noSnapshot,
		GetContext = noSnapshot,
		GetEffectiveBindings = noSnapshot,
		BindActionLabel = reject,
		UnbindActionLabel = reject,
		ObservePrimitive = function(): () -> ()
			return disconnect
		end,
		RegisterGraphValidator = function(): () -> ()
			return disconnect
		end,
		ObserveConfigurationCommit = function(): () -> ()
			return disconnect
		end,
		IsPressEpochActive = function(): boolean
			return false
		end,
		PrepareSource = function(): (Types.PreparedInputUpdate?, string?)
			return nil, unavailable()
		end,
		CommitPrepared = reject,
		PrepareEpochInvalidation = function(): (Types.PreparedInputInvalidation?, string?)
			return nil, unavailable()
		end,
		CommitEpochInvalidation = reject,
		Destroy = function(): ()
			if destroyed then
				return
			end

			destroyed = true
			options.Native.DestroyContainer()
		end,
	}
end

return InputOwner
