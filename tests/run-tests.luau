local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local runCLI = require(ReplicatedStorage.DevPackages.Jest).runCLI
local coverage = require(ReplicatedStorage.DevPackages["roblox-coverage"])

local COVERAGE_START_MARKER = "__KRF_COVERAGE_START__"
local COVERAGE_END_MARKER = "__KRF_COVERAGE_END__"
local COVERAGE_CHUNK_SIZE = 8000

local processServiceExists, ProcessService = pcall(function()
	-- selene: allow(incorrect_standard_library_use)
	return game:GetService("ProcessService")
end)

coverage.instrument({
	ReplicatedStorage.Packages.KRF,
}, {})

local status, result = runCLI(ReplicatedStorage.Packages, {
	verbose = false,
	ci = true,
}, { ReplicatedStorage.Tests }):awaitStatus()

local coverageReport = coverage.istanbul()
local coverageJson = HttpService:JSONEncode(coverageReport)

print(COVERAGE_START_MARKER)
for startIndex = 1, string.len(coverageJson), COVERAGE_CHUNK_SIZE do
	local endIndex = math.min(startIndex + COVERAGE_CHUNK_SIZE - 1, string.len(coverageJson))
	print(string.sub(coverageJson, startIndex, endIndex))
end
print(COVERAGE_END_MARKER)

coverage.cleanup()

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
