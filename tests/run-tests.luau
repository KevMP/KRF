local ReplicatedStorage = game:GetService("ReplicatedStorage")

local runCLI = require(ReplicatedStorage.DevPackages.Jest).runCLI

local processServiceExists, ProcessService = pcall(function()
	return game:GetService("ProcessService")
end)

local status, result = runCLI(ReplicatedStorage.Packages, {
	verbose = false,
	ci = true,
}, { ReplicatedStorage.Tests }):awaitStatus()

local failed = status ~= "Resolved" or result.results.numFailedTestSuites ~= 0 or result.results.numFailedTests ~= 0

if failed then
	if processServiceExists then
		ProcessService:ExitAsync(1)
	else
		error("Jest failed (ProcessService unavailable)")
	end
else
	if processServiceExists then
		ProcessService:ExitAsync(0)
	end
end

return nil
