--!strict
-- Open Cloud task run against a consumer place built from an installed KRF package.
-- It uses only the package's public root module, as a game would after `wally install`.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local function check(condition: boolean, message: string): ()
	if not condition then
		error(`KRF consumer smoke failed: {message}`, 0)
	end
end

local function createMark(): KRF.ActionDefinition
	return {
		id = "Smoke.Mark",
		visibility = "ClientVisible",
		autoGrant = true,
		costs = { ["Smoke.Energy"] = 3 },
		activeTags = { "Smoke.Marking" },
		appliedTags = { "Smoke.Marked" },
		onStart = function(_ctx: KRF.ActionExecutionContext): () end,
	}
end

local config: KRF.ServerStartConfig = {
	tags = {
		{ id = "Smoke.Marking", visibility = "ClientVisible", duplicateBehavior = "Stack" },
		{ id = "Smoke.Marked", visibility = "ClientVisible", duplicateBehavior = "Refresh", defaultDuration = 60 },
	},
	resources = {
		{
			id = "Smoke.Energy",
			visibility = "ClientVisible",
			max = { value = 10 },
			initialValue = 10,
			autoAssign = true,
		},
	},
	actions = { createMark },
}

local started: boolean, failure: KRF.ServerStartupFailure? = KRF.Server.Init(config)
check(started, if failure then `Server.Init failed: {failure.system}: {failure.reason}` else "Server.Init failed")

local model = Instance.new("Model")
model.Name = "SmokeActor"
model.Parent = workspace

local actor: KRF.Actor?, registerFailure: string? = KRF.ActorRuntime.RegisterActor(model)
check(actor ~= nil, `RegisterActor failed: {registerFailure}`)
local registered = actor :: KRF.Actor

local actions = registered:GetController("ActionController") :: KRF.ActionController
local resources = registered:GetController("ResourceController") :: KRF.ResourceController
local tags = registered:GetController("TagController") :: KRF.TagController

local result: KRF.ActionRequestResult = actions:RequestAction("Smoke.Mark")
check(result.accepted, `RequestAction rejected: {if result.accepted then "" else result.reason}`)
local sequenceId = (result :: KRF.ActionRequestAccepted).sequenceId

check(resources:GetCurrent("Smoke.Energy") == 7, "Action cost was not paid exactly once")
check(tags:HasTag("Smoke.Marking"), "Owned active Tag was not applied")
check(tags:HasTag("Smoke.Marked"), "Applied Tag was not applied")

local ended: boolean, endFailure: string? = actions:EndAction(sequenceId)
check(ended, `EndAction failed: {endFailure}`)
check(not tags:HasTag("Smoke.Marking"), "Owned active Tag survived the Action")
check(tags:HasTag("Smoke.Marked"), "Applied Tag did not keep its own lifetime")

local unregistered: boolean, unregisterFailure: string? = KRF.ActorRuntime.UnregisterActor(registered, "SmokeComplete")
check(unregistered, `UnregisterActor failed: {unregisterFailure}`)
model:Destroy()

print("KRF consumer smoke passed")

return true
