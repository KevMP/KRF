--!strict
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local RunService = game:GetService("RunService")

assert(RunService:IsEdit(), "Native N5 launcher requires the Edit DataModel")
local result: any = StudioTestService:ExecuteMultiplayerTestAsync(2, "KRFN5ActorViews")
local encoded: string = HttpService:JSONEncode(result)
if type(result) == "table" and result.success == true then
	print("__KRF_NATIVE_N5_PASS__ " .. encoded)
else
	print("__KRF_NATIVE_N5_FAIL__ " .. encoded)
	error("Native N5 ActorView test failed: " .. encoded, 0)
end

return nil
