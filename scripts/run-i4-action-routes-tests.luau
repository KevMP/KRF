--!strict
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local RunService = game:GetService("RunService")
assert(RunService:IsEdit(), "Native I4 launcher requires the Edit DataModel")
local result: any = StudioTestService:ExecuteMultiplayerTestAsync(2, "KRFI4ActionRoutes")
local encoded: string = HttpService:JSONEncode(result)
if type(result) == "table" and result.success == true then
	print("__KRF_NATIVE_I4_PASS__ " .. encoded)
else
	print("__KRF_NATIVE_I4_FAIL__ " .. encoded)
	error("Native I4 Action route test failed: " .. encoded, 0)
end
return nil
