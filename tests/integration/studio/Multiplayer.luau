--!strict
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local StudioTestService = game:GetService("StudioTestService")

type TestArguments = string | { testName: string, clientCount: number, soakSmoke: boolean }

return function(clientCount: number, arguments: TestArguments, marker: string, resultBlock: string?)
	assert(RunService:IsEdit(), "Native launcher requires the Edit DataModel")

	local result: unknown = StudioTestService:ExecuteMultiplayerTestAsync(clientCount, arguments)
	local encoded: string = HttpService:JSONEncode(result)
	local passed = type(result) == "table" and (result :: { success: unknown }).success == true
	local statusMarker = "__KRF_NATIVE_" .. marker .. (if passed then "_PASS__" else "_FAIL__")

	if resultBlock then
		print("__KRF_" .. resultBlock .. "_START__")

		for offset: number = 1, #encoded, 8000 do
			print(string.sub(encoded, offset, offset + 7999))
		end

		print("__KRF_" .. resultBlock .. "_END__")
		print(statusMarker)
	else
		print(statusMarker .. " " .. encoded)
	end

	if not passed then
		error("Native " .. marker .. " test failed", 0)
	end
end
