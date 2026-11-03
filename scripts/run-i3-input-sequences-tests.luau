--!strict
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local RunService = game:GetService("RunService")

assert(RunService:IsEdit(), "Native I3 launcher requires the Edit DataModel")
local result: any = StudioTestService:ExecuteMultiplayerTestAsync(2, "KRFI3InputSequences")
local encoded: string = HttpService:JSONEncode(result)
if type(result) == "table" and result.success == true then
	print("__KRF_NATIVE_I3_PASS__ " .. encoded)
else
	print("__KRF_NATIVE_I3_FAIL__ " .. encoded)
	error("Native I3 sequence test failed: " .. encoded, 0)
end

return nil
