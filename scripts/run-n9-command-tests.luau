--!strict
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local RunService = game:GetService("RunService")

assert(RunService:IsEdit(), "Native N9 launcher requires the Edit DataModel")
local result: any = StudioTestService:ExecuteMultiplayerTestAsync(2, "KRFN9Commands")
local encoded: string = HttpService:JSONEncode(result)
if type(result) == "table" and result.success == true then
	print("__KRF_NATIVE_N9_PASS__ " .. encoded)
else
	print("__KRF_NATIVE_N9_FAIL__ " .. encoded)
	error("Native N9 command test failed: " .. encoded, 0)
end
return nil
