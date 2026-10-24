--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Schema = require(ReplicatedStorage.Packages.KRF.shared.Networking.Schema)
local Baseline = require(ReplicatedStorage.NetworkingBaselineScenario)

local Scenario = {}
Scenario.version = 2
Scenario.modes = { "Sustained", "Uneven", "Overload", "Late", "Pressure" }
Scenario.hz = 30
Scenario.ticks = 180
Scenario.request = Schema.Struct({ serial = Schema.U32, sentAt = Schema.F64 })
Scenario.result = Schema.Struct({ serial = Schema.U32 })
Scenario.summarize = Baseline.summarize

function Scenario.offered(tick: number, index: number, clients: number, mode: string): number
	if mode == "Late" then
		if tick == 1 then
			return if index == clients then 8 else 64
		end

		return if index == clients and tick % 15 == 0 then 1 else 0
	elseif mode == "Pressure" then
		if index == clients then
			return if tick % 30 >= 25 and tick % 30 < 30 then 1 else 0
		end

		return if tick % 4 == 1 then 8 else 0
	elseif mode == "Overload" then
		return if tick == 1 then 80 else 0
	elseif mode == "Uneven" then
		if index == 1 then
			return if tick % 2 == 0 then 3 else 0
		elseif index == clients then
			return if tick % 30 == 0 then 4 else 0
		end

		return if tick % 6 == 0 then 1 else 0
	end

	return if tick % 2 == 0 then 1 else 0
end

function Scenario.delay(tick: number, index: number, clients: number, mode: string): number
	return if mode == "Late" and tick == 1 and index == clients then 0.001 else 0
end

return Scenario
