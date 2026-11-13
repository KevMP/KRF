--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local KRF = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("KRF")
local ActorTypes = require(KRF.client.Actor.types)
local ActionTypes = require(KRF.client.Action.types)
local InputTypes = require(KRF.client.Input.types)
local ControlsTypes = require(KRF.client.Controls.types)
local Client = require(KRF.client)
local Registry: ActorTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local Actions: ActionTypes.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Input: InputTypes.InputRuntime = require(KRF.client.Input.InputRuntime)
local Controls: ControlsTypes.ClientControls = require(KRF.client.Controls.ClientControls)
local Schemas = require(ReplicatedStorage.FireDemoShared.RequestSchemas)
local Config = require(script.Parent.InputConfig)
local Panel = require(script.Parent.Panel)

local panel: Panel.View = Panel.new()
panel.Log("Starting normal KRF client handshake...")
local started: boolean, failure = Client.Init({ actionRequestSchemas = Schemas, actionInputPolicies = Config.Policies })
assert(started, if failure ~= nil then failure.system .. ":" .. failure.reason else "ClientStartupFailed")

assert(Controls.Apply({
	inputs = { { kind = "Set", sourceId = "FireDemo", definition = Config.Source } },
	contexts = { { contextId = "FireDemo", enabled = true } },
}))

local observations = Actions.OnActionRequest:Connect(panel.Observe)

local primitiveInput = Input.OnInput:Connect(function(event: InputTypes.SemanticInputEvent): ()
	panel.Log("Input " .. event.inputId .. " " .. event.kind)
end)

local sequences = Input.OnSequenceMatched:Connect(function(event: InputTypes.SequenceMatchEvent): ()
	panel.Log("Sequence " .. event.sequenceId .. " matched")
end)

local controlled: ActorTypes.ActorView? = nil
local target: ActorTypes.ActorView? = nil
local elapsed: number = 1

local heartbeat: RBXScriptConnection = RunService.Heartbeat:Connect(function(deltaTime: number): ()
	elapsed += deltaTime

	if elapsed < 0.1 then
		return
	end

	elapsed = 0
	local character: Model? = Players.LocalPlayer.Character
	local actor: ActorTypes.ActorView? = if character ~= nil then Registry.GetActorViewByModel(character) else nil
	local dummy: Instance? = workspace:FindFirstChild("TrainingDummy")

	local dummyView: ActorTypes.ActorView? = if dummy ~= nil and dummy:IsA("Model")
		then Registry.GetActorViewByModel(dummy)
		else nil

	local actorChanged: boolean = actor ~= controlled

	if actorChanged then
		local profiles: { ControlsTypes.ProfileSourceChange } = {}

		if controlled ~= nil and controlled:IsAvailable() then
			table.insert(profiles, { kind = "Remove" :: "Remove", actor = controlled, sourceId = "FireDemo" })
		end

		if actor ~= nil then
			table.insert(
				profiles,
				{ kind = "Set" :: "Set", actor = actor, sourceId = "FireDemo", profile = Config.Profile }
			)
		end

		assert(Controls.Apply({ profiles = profiles, selection = { kind = "Set", actor = actor } }))
		controlled = actor
	end

	if actorChanged or dummyView ~= target then
		target = dummyView
		panel.Bind(controlled, target)
	end

	panel.Render()
end)

script.Destroying:Connect(function(): ()
	heartbeat:Disconnect()
	observations:Disconnect()
	primitiveInput:Disconnect()
	sequences:Disconnect()
	local profiles: { ControlsTypes.ProfileSourceChange } = {}

	if controlled ~= nil and controlled:IsAvailable() then
		table.insert(profiles, { kind = "Remove" :: "Remove", actor = controlled, sourceId = "FireDemo" })
	end

	Controls.Apply({
		inputs = { { kind = "Remove", sourceId = "FireDemo" } },
		profiles = profiles,
		selection = { kind = "Set", actor = nil },
	})

	panel.Destroy()
end)
