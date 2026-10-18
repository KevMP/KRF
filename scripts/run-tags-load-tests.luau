--!strict
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")
assert(game:GetService("RunService"):IsEdit(), "Load launcher requires the Edit DataModel")
local result: any = StudioTestService:ExecuteMultiplayerTestAsync(2, "KRFTagsLoad")
local encoded: string = HttpService:JSONEncode(result)
print("__KRF_TAGS_LOAD_RESULT_START__")
for offset: number = 1, #encoded, 8000 do
	print(string.sub(encoded, offset, offset + 7999))
end
print("__KRF_TAGS_LOAD_RESULT_END__")
if type(result) == "table" and result.success == true then
	print("__KRF_NATIVE_TAGS_LOAD_PASS__")
else
	print("__KRF_NATIVE_TAGS_LOAD_FAIL__")
	error("Native Tags load test failed", 0)
end
return nil
