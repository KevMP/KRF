--!strict
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local RunService = game:GetService("RunService")
assert(RunService:IsEdit(), "Native I7 launcher requires the Edit DataModel")
local result: unknown = StudioTestService:ExecuteMultiplayerTestAsync(2, "KRFI7Controls")
local encoded: string = HttpService:JSONEncode(result)
if type(result) == "table" and (result :: { [string]: unknown }).success == true then
	print("__KRF_NATIVE_I7_PASS__ " .. encoded)
else
	print("__KRF_NATIVE_I7_FAIL__ " .. encoded)
	error("Native I7 control test failed: " .. encoded, 0)
end
return nil
