--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local KRF = ReplicatedStorage.Packages.KRF
local Server = require(KRF.server)
local ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local ActorTypes = require(KRF.server.Actor.types)
local ActionTypes = require(KRF.server.Action.types)
local TagTypes = require(KRF.server.Tags.types)
local ResourceTypes = require(KRF.server.Resource.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local WireTypes = require(KRF.shared.Networking.types)
local Schema = require(KRF.shared.Networking.Schema)
local WireCodec = require(KRF.shared.Networking.ActorStreamCodec)
local Awareness = require(KRF.server.Networking.ActorAwarenessRuntime)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Hints: NetworkingTypes.HintRuntime = require(KRF.server.Networking.HintRuntime)

local control: RemoteEvent = ReplicatedStorage:WaitForChild("PresentationTestControl") :: RemoteEvent
local omitActions: boolean = true
local awareness: NetworkingTypes.ActorAwarenessRuntime? = nil
local codecCompile = WireCodec.Compile
local createAwareness = Awareness.new

-- Vary the membership of the initial wire baseline while retaining normal
-- startup, capture, reliable delivery and client consumer installation.
WireCodec.Compile = function(
	protocol: WireTypes.ClientProtocol,
	schemas: WireTypes.ActorSchemaCatalog
): WireTypes.ActorStreamCodec
	local codec: WireTypes.ActorStreamCodec = codecCompile(protocol, schemas)
	local encode = codec.EncodeBaseline

	codec.EncodeBaseline = function(domains: { [string]: WireTypes.ActorDomainTruth }): (buffer?, string?)
		if omitActions then
			domains = table.clone(domains)
			domains["KRF.Actions"] = nil
		end

		return encode(domains)
	end

	return codec
end

Awareness.new = function(publication, catalog, protocol, dependencies, options): NetworkingTypes.ActorAwarenessRuntime
	local runtime: NetworkingTypes.ActorAwarenessRuntime =
		createAwareness(publication, catalog, protocol, dependencies, options)

	awareness = runtime

	return runtime
end

Players.CharacterAutoLoads = false

local validPlayer: Player? = nil

local function assign(player: Player): ()
	if validPlayer == nil then
		validPlayer = player
	end

	player:SetAttribute("ValidPresentationCatalog", player == validPlayer)
end

Players.PlayerAdded:Connect(assign)

for _, player: Player in Players:GetPlayers() do
	assign(player)
end

local initialized, failure = Server.Init({
	tags = {
		{ id = "Charging", duplicateBehavior = "Ignore", visibility = "ClientVisible" },
		{ id = "Burning", duplicateBehavior = "Ignore", visibility = "ClientVisible" },
		{ id = "Private.Hidden", duplicateBehavior = "Ignore", visibility = "ServerOnly" },
	},
	resources = {
		{ id = "Mana", max = { value = 100 }, initialValue = 100, visibility = "ClientVisible", autoAssign = true },
		{
			id = "Private.Mana",
			max = { value = 100 },
			initialValue = 100,
			visibility = "ServerOnly",
			autoAssign = true,
		},
	},
	actions = {
		function(): ActionTypes.ActionDefinition
			return { id = "Sword.Swing", visibility = "ClientVisible", autoGrant = true }
		end,
	},
	hints = {
		{ id = "Impact.World", direction = "ServerToClient", target = "None", mode = "Pulse", payload = Schema.U8 },
		{ id = "Impact.Actor", direction = "ServerToClient", target = "Actor", mode = "Pulse", payload = Schema.U8 },
	},
})

WireCodec.Compile = codecCompile
Awareness.new = createAwareness
assert(initialized, if failure ~= nil then failure.reason else "Server.Init failed")

local model: Model = Instance.new("Model")
model.Name = "PresentationSubject"

local root: Part = Instance.new("Part")
root.Anchored = true
root.Parent = model
model.PrimaryPart = root
model.Parent = workspace
local actor: ActorTypes.Actor?, reason: string? = ActorRuntime.RegisterActor(model)
assert(actor ~= nil, reason)
local controller: ActionTypes.ActionController = actor:GetController("ActionController") :: ActionTypes.ActionController
assert(controller:RequestAction("Sword.Swing").accepted, "Expected pre-baseline Action")
local tags: TagTypes.TagController = actor:GetController("TagController") :: TagTypes.TagController
assert(tags:AddTag("Burning"), "Expected pre-baseline Tag")

local phase: string = "Ready"
local invalidPassed: boolean = false
local validPassed: boolean = false
local finished: boolean = false

local function finish(success: boolean, detail: string?): ()
	if finished then
		return
	end

	finished = true
	Networking.Destroy()
	model:Destroy()
	StudioTestService:EndTest({ success = success, reason = detail, phase = phase })
end

local function send(player: Player, nextPhase: string): ()
	phase = nextPhase
	control:FireClient(player, phase, actor:GetId())
end

control.OnServerEvent:Connect(function(player: Player, report: string, clientFailure: string?)
	if finished then
		return
	end

	local succeeded: boolean, detail: any = pcall(function()
		assert(clientFailure == nil, clientFailure)
		assert(validPlayer ~= nil, "Expected assigned native roles")

		if player ~= validPlayer then
			assert(report == "Invalid" and not Networking.IsClientReady(player), "Invalid client started Networking")
			invalidPassed = true
		else
			assert(Networking.IsClientReady(player), "Expected native client startup")
			assert(report == phase, "Unexpected native phase " .. report)

			if phase == "Ready" then
				send(player, "Initial")
			elseif phase == "Initial" then
				omitActions = false
				assert(awareness ~= nil, "Normal startup did not install awareness")
				local handle: number = assert(awareness:GetHandle(player, actor), "Expected native Actor handle")

				local replaced, replacementReason =
					Networking.RequestReplacementBaseline(player, handle, "PresentationTest")

				assert(replaced, replacementReason)
				send(player, "Replacement")
			elseif phase == "Replacement" then
				assert(controller:RequestAction("Sword.Swing").accepted, "Expected live Sword.Swing start")
				assert(controller:RequestAction("Sword.Swing").accepted, "Expected live Sword.Swing start")
				send(player, "Live")

				task.spawn(function()
					for _ = 1, 10 do
						if phase ~= "Live" or finished then
							break
						end

						assert(Hints.SendTo(player, "Impact.World", nil, 21), "Expected world Hint admission")
						assert(Hints.SendTo(player, "Impact.Actor", actor, 22), "Expected Actor Hint admission")
						task.wait(0.25)
					end
				end)
			elseif phase == "Live" then
				local resources: ResourceTypes.ResourceController =
					actor:GetController("ResourceController") :: ResourceTypes.ResourceController

				assert(tags:AddTag("Charging"))
				assert(tags:AddTag("Private.Hidden"))
				assert(resources:SetCurrent("Mana", 80))
				assert(resources:SetCurrent("Private.Mana", 80))
				send(player, "Followups")

				task.spawn(function()
					for _ = 1, 10 do
						if phase ~= "Followups" or finished then
							break
						end

						assert(Hints.SendTo(player, "Impact.Actor", actor, 22))
						task.wait(0.1)
					end
				end)
			elseif phase == "Followups" then
				assert(controller:EndAction(2))
				assert(tags:RemoveTag("Burning"), "Expected live Tag removal")
				send(player, "EndedFirst")
			elseif phase == "EndedFirst" then
				assert(controller:InterruptAction(3, "NativePresentationTest"))
				send(player, "Interrupted")
			elseif phase == "Interrupted" then
				assert(ActorRuntime.UnregisterActor(actor), "Expected native Actor retirement")
				send(player, "Removed")
			elseif phase == "Removed" then
				validPassed = true
			end
		end

		if validPassed and invalidPassed then
			finish(true, nil)
		end
	end)

	if not succeeded then
		finish(false, tostring(detail))
	end
end)

task.delay(85, function()
	finish(false, "Presentation native fixture timed out")
end)
