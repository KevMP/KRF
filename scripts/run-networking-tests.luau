--!strict
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")

local result: any = StudioTestService:ExecuteMultiplayerTestAsync(2, "KRFNetworking")
assert(
	type(result) == "table" and result.success == true,
	"Native networking test failed: " .. HttpService:JSONEncode(result)
)
print("__KRF_NATIVE_NETWORKING_PASS__ " .. HttpService:JSONEncode(result))

return nil
