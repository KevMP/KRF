local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function report(result: { [string]: any }): ()
	print("__KRF_TEST_RESULT__ " .. HttpService:JSONEncode(result))
end

local tests: Instance? = ReplicatedStorage:FindFirstChild("KRFTests")
local devPackages: Instance? = ReplicatedStorage:FindFirstChild("DevPackages")
local jest: Instance? = if devPackages ~= nil then devPackages:FindFirstChild("Jest") else nil

if tests == nil or jest == nil then
	report({
		error = if tests == nil then "The test place has no tests folder" else "DevPackages.Jest is not installed",
	})
	return nil
end

print("__KRF_TEST_OUTPUT_BEGIN__")
local ran: boolean, status: any, result: any = pcall(function()
	local runCLI = (require :: any)(jest).runCLI
	return runCLI(tests, { ci = true, verbose = true }, { tests }):awaitStatus()
end)
print("__KRF_TEST_OUTPUT_END__")

if not ran then
	report({ error = tostring(status) })
elseif status ~= "Resolved" then
	report({ error = tostring(result) })
else
	local results: any = result.results
	report({
		numTotalTests = results.numTotalTests,
		numPassedTests = results.numPassedTests,
		numFailedTests = results.numFailedTests,
		numTotalTestSuites = results.numTotalTestSuites,
		numFailedTestSuites = results.numFailedTestSuites,
		numRuntimeErrorTestSuites = results.numRuntimeErrorTestSuites,
	})
end

return nil
