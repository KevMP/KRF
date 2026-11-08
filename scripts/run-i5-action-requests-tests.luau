--!strict
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local RunService = game:GetService("RunService")
assert(RunService:IsEdit(), "Native I5 launcher requires the Edit DataModel")
local result: any = StudioTestService:ExecuteMultiplayerTestAsync(2, "KRFI5ActionRequests")
local encoded: string = HttpService:JSONEncode(result)
if type(result) == "table" and result.success == true then
	print("__KRF_NATIVE_I5_PASS__ " .. encoded)
else
	print("__KRF_NATIVE_I5_FAIL__ " .. encoded)
	error("Native I5 Action request test failed: " .. encoded, 0)
end
return nil
