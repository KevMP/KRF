--!strict
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local StudioTestService = game:GetService("StudioTestService")

if not RunService:IsEdit() then
	return
end
task.defer(function()
	local control: Instance? = game:GetService("ReplicatedStorage"):WaitForChild("N4AssociationTestControl", 5)
	if control == nil then
		return
	end
	local completed: boolean, result: any = pcall(function()
		return StudioTestService:ExecuteMultiplayerTestAsync(2, "KRFN4Association")
	end)
	if completed and type(result) == "table" and result.success == true then
		print("__KRF_NATIVE_N4_ASSOCIATION_PASS__ " .. HttpService:JSONEncode(result))
	else
		warn(
			"__KRF_NATIVE_N4_ASSOCIATION_FAIL__ "
				.. tostring(if completed then HttpService:JSONEncode(result) else result)
		)
	end
end)
