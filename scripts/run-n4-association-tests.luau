--!strict
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")

-- Run in the Edit DataModel of the place built from n4-association-test.project.json.
local result: any = StudioTestService:ExecuteMultiplayerTestAsync(2, "KRFN4Association")
assert(
	type(result) == "table" and result.success == true,
	"Native N4 association test failed: " .. HttpService:JSONEncode(result)
)
print("__KRF_NATIVE_N4_ASSOCIATION_PASS__ " .. HttpService:JSONEncode(result))

return nil
