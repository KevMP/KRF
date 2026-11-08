--!strict
local Types = require(script.Parent.Parent.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local InputState = require(script.Parent.Parent.Parent.Input.utils.InputRuntimeState)
local State = require(script.Parent.ClientActionRuntimeState)
local Owner = require(script.Parent.Parent.ClientActionOwner)
local RequestState = require(script.Parent.Parent.Parent.ActionRequest.utils.ClientActionRequestState)
local RequestTypes = require(script.Parent.Parent.Parent.ActionRequest.types)
local Lifecycle = require(script.Parent.ActionInputLifecycle)
local Installation = {}

function Installation.Install(isReady: () -> boolean, policies: Types.ActionInputCatalog?): () -> ()
	local input: InputTypes.InputOwner = assert(InputState.Get(), "InputOwnerUnavailable")

	local previous: Types.ClientActionOwner? = State.Get()

	if previous ~= nil then
		previous.Destroy()
	end

	local owner: Types.ClientActionOwner? = nil
	local lifecycle: Types.ActionInputOwner? = nil
	local requests: RequestTypes.ClientActionRequestRuntime? = RequestState.Get()

	local function report(reason: string): ()
		if reason ~= "ResolvedNoAction" then
			warn("[ActionRoutes] " .. reason)
		end
	end

	if requests ~= nil and policies ~= nil then
		lifecycle = Lifecycle.new({
			Input = input,
			Requests = requests,
			Policies = policies,
			IsReady = isReady,
			Report = report,
		})
	end

	local installedOk: boolean, failure: any = pcall(function(): ()
		owner = Owner.new({
			OnDestroyed = function(): ()
				if lifecycle ~= nil then
					lifecycle.Destroy()

					if State.GetInput() == lifecycle then
						State.InstallInput(nil)
					end
				end

				if State.Get() == owner then
					State.Install(nil)
				end
			end,
			Input = input,
			IsReady = isReady,
			Sink = if lifecycle ~= nil then lifecycle.Select else function() end,
			ActivationGuard = if lifecycle ~= nil then lifecycle.Guard else nil,
			ReportFault = report,
		})

		local installedOwner: Types.ClientActionOwner = assert(owner, "Expected constructed Action owner")

		if lifecycle ~= nil then
			lifecycle.Attach({
				GetControlledActor = installedOwner.GetControlledActor,
				GetEffectiveRoute = installedOwner.GetEffectiveRoute,
				ObserveRoutes = installedOwner.ObserveRoutes,
			})
		end
	end)

	if not installedOk then
		if owner ~= nil then
			owner.Destroy()
		elseif lifecycle ~= nil then
			lifecycle.Destroy()
		end

		error(failure, 0)
	end

	State.Install(owner)
	State.InstallInput(lifecycle)
	local installed: Types.ClientActionOwner = assert(owner, "Expected installed Action owner")
	local active: boolean = true

	return function(): ()
		if not active then
			return
		end

		active = false

		if State.Get() == installed then
			State.Install(nil)
		end

		installed.Destroy()
	end
end

return Installation
