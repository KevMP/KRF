--!strict
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
assert(game:GetService("RunService"):IsEdit(), "Load launcher requires the Edit DataModel")
local clientCount = 2 -- Replaced in the run-local copy by the PowerShell launcher.
local soakSmoke = false -- Replaced only for a short soak setup check.
local result: any = StudioTestService:ExecuteMultiplayerTestAsync(clientCount, {
	testName = "KRFNetworkingBaseline",
	clientCount = clientCount,
	soakSmoke = soakSmoke,
})
local encoded: string = HttpService:JSONEncode(result)
print("__KRF_NETWORKING_BASELINE_RESULT_START__")
for offset: number = 1, #encoded, 8000 do
	print(string.sub(encoded, offset, offset + 7999))
end
print("__KRF_NETWORKING_BASELINE_RESULT_END__")
if type(result) == "table" and result.success == true then
	print("__KRF_NATIVE_NETWORKING_BASELINE_PASS__")
else
	print("__KRF_NATIVE_NETWORKING_BASELINE_FAIL__")
	error("Native Networking baseline test failed", 0)
end
return nil
