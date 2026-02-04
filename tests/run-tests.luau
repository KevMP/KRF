local ReplicatedStorage = game:GetService("ReplicatedStorage")

local runCLI = require(ReplicatedStorage.DevPackages.Jest).runCLI

local processServiceExists, ProcessService = pcall(function()
	return game:GetService("ProcessService")
end)

local status, result = runCLI(ReplicatedStorage.Packages, {
	verbose = false,
	ci = false,
}, { ReplicatedStorage.Tests }):awaitStatus()

if status == "Resolved" and result.results.numFailedTestSuites == 0 and result.results.numFailedTests == 0 then
	if processServiceExists then
		ProcessService:ExitAsync(0)
	end
end

if processServiceExists then
	ProcessService:ExitAsync(1)
end

return nil
