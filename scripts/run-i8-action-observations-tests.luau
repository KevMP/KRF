--!strict
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local RunService = game:GetService("RunService")
assert(RunService:IsEdit(), "Native I8 launcher requires the Edit DataModel")
local result: unknown = StudioTestService:ExecuteMultiplayerTestAsync(2, "KRFI8ActionObservations")
local encoded: string = HttpService:JSONEncode(result)
if type(result) == "table" and (result :: { [string]: unknown }).success == true then
	print("__KRF_NATIVE_I8_PASS__ " .. encoded)
else
	print("__KRF_NATIVE_I8_FAIL__ " .. encoded)
	error("Native I8 observation test failed: " .. encoded, 0)
end
return nil
