--!strict
local SignalTypes = require(script.Parent.types)

type OwnedSignals = SignalTypes.OwnedSignals

export type OwnedSignal = {
	Destroy: (any) -> (),
}

local OwnedSignals = {}

function OwnedSignals.new(signals: { OwnedSignal }): OwnedSignals
	local ownedSignals: OwnedSignals = {} :: OwnedSignals

	local signalsDestroyed: boolean = false
	local destroyRequested: boolean = false
	local deferredDestroyDepth: number = 0
	local ownedSignalsList: { OwnedSignal } = table.clone(signals)

	local function destroySignals(): ()
		if signalsDestroyed then
			return
		end

		signalsDestroyed = true

		for _, signal: OwnedSignal in ipairs(ownedSignalsList) do
			signal:Destroy()
		end

		table.clear(ownedSignalsList)
	end

	local function flushDestroyIfReady(): ()
		if destroyRequested and deferredDestroyDepth == 0 then
			destroySignals()
		end
	end

	function ownedSignals:WithDeferredDestroy(callback: () -> ()): ()
		if signalsDestroyed then
			error("OwnedSignals:WithDeferredDestroy called after signals were destroyed", 2)
		end

		deferredDestroyDepth += 1

		local ok: boolean, err: unknown? = pcall(callback :: any)

		deferredDestroyDepth -= 1
		flushDestroyIfReady()

		if not ok then
			error(err, 0)
		end
	end

	function ownedSignals:Destroy(): ()
		if destroyRequested then
			return
		end

		destroyRequested = true

		if deferredDestroyDepth > 0 then
			return
		end

		destroySignals()
	end

	return ownedSignals
end

return OwnedSignals
