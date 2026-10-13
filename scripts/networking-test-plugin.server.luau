--!strict
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")

-- Local test launcher only; never starts on ordinary places or simulations.
if not RunService:IsEdit() then
	return
end
task.defer(function(): ()
	local control: Instance? = game:GetService("ReplicatedStorage"):WaitForChild("NetworkingTestControl", 15)
	if control == nil or not control:IsA("RemoteEvent") then
		return
	end
	print("__KRF_NATIVE_NETWORKING_START__")
	local completed: boolean, result: any = pcall(function(): any
		return StudioTestService:ExecuteMultiplayerTestAsync(2, "KRFNetworking")
	end)
	if completed and type(result) == "table" and result.success == true then
		print("__KRF_NATIVE_NETWORKING_PASS__ " .. HttpService:JSONEncode(result))
	else
		warn(
			"__KRF_NATIVE_NETWORKING_FAIL__ " .. tostring(if completed then HttpService:JSONEncode(result) else result)
		)
	end
end)
