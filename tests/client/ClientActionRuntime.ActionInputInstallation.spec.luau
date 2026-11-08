--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local RequestTypes = require(KRF.client.ActionRequest.types)
local SharedTypes = require(KRF.shared.ActionRequest.types)
local Catalog = require(KRF.shared.ActionRequest.ActionRequestCatalog)
local Validator = require(KRF.client.Action.ActionInputPolicyValidator)
local Owner = require(KRF.client.Action.ClientActionOwner)
local Lifecycle = require(KRF.client.Action.utils.ActionInputLifecycle)
local Installation = require(KRF.client.Action.utils.ClientActionInstallation)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Requests = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local Utils = require(script.Parent.Utils.ActionInputTestUtils)
local fixture: Utils.Fixture
local policies: Types.ActionInputCatalog
local originalOwnerNew = Owner.new
local originalLifecycleNew = Lifecycle.new

beforeEach(function()
	fixture = Utils.new()
	Utils.ready(fixture, Utils.policies())
	local catalog: SharedTypes.ActionRequestCatalog = assert(Catalog.Compile(fixture.schemas))
	policies = assert(Validator.Compile(Utils.policies(), catalog))
end)

afterEach(function()
	Owner.new = originalOwnerNew
	Lifecycle.new = originalLifecycleNew
	Utils.destroy(fixture)
end)

it("cleans new lifecycle subscriptions when route-owner construction fails", function()
	Owner.new = function(): Types.ClientActionOwner
		error("Owner installation failed", 0)
	end

	local ok: boolean, failure: any = pcall(Installation.Install, function(): boolean
		return true
	end, policies)

	expect(ok).toBe(false)
	expect(failure).toBe("Owner installation failed")
	expect(State.Get()).toBeNil()
	expect(State.GetInput()).toBeNil()
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())

	for _ = 1, 16 do
		requests:ObserveAdmissions(function() end)
	end
end)

it("destroys the constructed owner and lifecycle when input attachment fails", function()
	local partial: Types.ActionInputOwner?

	Lifecycle.new = function(options: Lifecycle.Options): Types.ActionInputOwner
		local created: Types.ActionInputOwner = originalLifecycleNew(options)
		partial = created

		created.Attach = function(): ()
			error("Input attachment failed", 0)
		end

		return created
	end

	local ok: boolean, failure: any = pcall(Installation.Install, function(): boolean
		return true
	end, policies)

	expect(ok).toBe(false)
	expect(failure).toBe("Input attachment failed")
	expect(State.Get()).toBeNil()
	expect(State.GetInput()).toBeNil()
	local destroyed: Types.ActionInputOwner = assert(partial, "Expected partial lifecycle")
	expect({ destroyed.RequestAction(fixture.actor, "Mode.Aura") }).toEqual({ nil, "ClientNotReady" })
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())

	for _ = 1, 16 do
		requests:ObserveAdmissions(function() end)
	end
end)

it("rolls back the first subscription when the second stream has exhausted its observer bound", function()
	assert(State.Get(), "Expected installed route owner").Destroy()
	local requests: RequestTypes.ClientActionRequestRuntime = assert(Requests.Get())

	for _ = 1, 16 do
		requests:ObserveOutcomes(function() end)
	end

	local ok: boolean, failure: any = pcall(Installation.Install, function(): boolean
		return true
	end, policies)

	expect(ok).toBe(false)
	expect(string.find(tostring(failure), "ActionRequestObserverLimitExceeded", 1, true) ~= nil).toBe(true)
	expect(State.Get()).toBeNil()
	expect(State.GetInput()).toBeNil()

	for _ = 1, 16 do
		requests:ObserveAdmissions(function() end)
	end
end)
