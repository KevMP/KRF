--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Scenario = require(ReplicatedStorage.NetworkingBaselineOriginalScenario)

-- Reuse the native baseline server/client without changing their startup,
-- consumer installation, transport observations or delivery assertions.
Scenario.populations = { { actors = 75, players = 25 }, { actors = 90, players = 30 } }
Scenario.modes = { "Heavy" }
Scenario.ticks = 1350

return Scenario
