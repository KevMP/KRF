--!strict
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
local RunService = game:GetService("RunService")

assert(RunService:IsEdit(), "Native I2 launcher requires the Edit DataModel")
local result: any = StudioTestService:ExecuteMultiplayerTestAsync(2, "KRFI2InputGestures")
local encoded: string = HttpService:JSONEncode(result)
if type(result) == "table" and result.success == true then
	print("__KRF_NATIVE_I2_PASS__ " .. encoded)
else
	print("__KRF_NATIVE_I2_FAIL__ " .. encoded)
	error("Native I2 gesture test failed: " .. encoded, 0)
end

return nil
