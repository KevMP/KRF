--!strict
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local RunService = game:GetService("RunService")

assert(RunService:IsEdit(), "Native N7 launcher requires the Edit DataModel")
local result: any = StudioTestService:ExecuteMultiplayerTestAsync(2, "KRFN7ResourcesView")
local encoded: string = HttpService:JSONEncode(result)
if type(result) == "table" and result.success == true then
	print("__KRF_NATIVE_N7_PASS__ " .. encoded)
else
	print("__KRF_NATIVE_N7_FAIL__ " .. encoded)
	error("Native N7 ResourcesView test failed: " .. encoded, 0)
end

return nil
