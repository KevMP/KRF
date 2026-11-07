--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.ActionRequest.types)
local ActorTypes = require(KRF.client.Actor.types)
local Client = require(KRF.client)
local State = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local Registry: ActorTypes.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local schemas = require(ReplicatedStorage.ActionRequestSchemas)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("ActionRequestControl") :: RemoteEvent
local player: Player = Players.LocalPlayer
local outcomes: { [number]: Types.ActionRequestOutcome } = {}

local function waitFor<T>(label: string, probe: () -> T?): T
	local deadline: number = os.clock() + 10

	while true do
		local value: T? = probe()

		if value ~= nil then
			return value
		end

		assert(os.clock() < deadline, "NativeActionRequestWait:" .. label)
		RunService.Heartbeat:Wait()
	end
end

local function viewFor(owner: Player, attribute: string): ActorTypes.ActorView
	return waitFor(attribute, function(): ActorTypes.ActorView?
		local actorId: any = owner:GetAttribute(attribute)

		return if type(actorId) == "string" then Registry.GetActorViewById(actorId) else nil
	end)
end

local function outcome(requestId: number?, status: string, label: string): Types.ActionRequestOutcome
	assert(requestId ~= nil, "NativeRequestNotAdmitted:" .. label)

	local settled: Types.ActionRequestOutcome = waitFor(label, function(): Types.ActionRequestOutcome?
		local current: Types.ActionRequestOutcome? = outcomes[requestId]

		return if current ~= nil and current.status ~= "Unknown" then current else nil
	end)

	assert(settled.status == status, label .. ":" .. settled.status .. ":" .. tostring(settled.reason))

	return settled
end

local function run(): any
	local initialized: boolean, failure = Client.Init({ actionRequestSchemas = schemas })
	assert(initialized, if failure ~= nil then failure.reason else "ClientInitFailed")
	local runtime: Types.ClientActionRequestRuntime = assert(State.Get(), "Client.InitDidNotInstallActionRequests")

	runtime:ObserveOutcomes(function(result: Types.ActionRequestOutcome): ()
		outcomes[result.admission.requestId] = result
	end)

	local own: ActorTypes.ActorView = viewFor(player, "CharacterActorId")
	local aim: any = { x = 1, y = 0, z = 0 }

	local fireball: Types.ActionRequestOutcome = outcome(
		(runtime:Start({ actor = own, actionId = "Combat.Fireball", origin = "Direct" }, { aim = aim })),
		"Accepted",
		"FireballStart"
	)

	assert(type(fireball.sequenceId) == "number", "FireballSequenceMissing")

	-- Release before acknowledgement: ordered egress keeps Stop behind its Start.
	local sprint: number? = runtime:Start({ actor = own, actionId = "Movement.Sprint", origin = "Input" })
	assert(sprint ~= nil, "SprintNotAdmitted")
	local sprintStop: number? = runtime:Stop(sprint)
	outcome(sprint, "Accepted", "SprintStart")
	outcome(sprintStop, "Accepted", "SprintStop")
	runtime:Retire(sprint)

	local cast: number? = runtime:Start(
		{ actor = own, actionId = "Technique.Cast", origin = "Direct" },
		{ techniqueId = "Chidori", aim = aim }
	)

	outcome(cast, "Accepted", "ServerOnlyCastStart")
	outcome(runtime:Stop(cast :: number, { releaseAim = aim }), "Accepted", "ServerOnlyCastStop")
	runtime:Retire(cast :: number)

	for _, peer: Player in Players:GetPlayers() do
		if peer ~= player then
			local foreign: ActorTypes.ActorView = viewFor(peer, "CharacterActorId")
			local denied: number? = runtime:Start({ actor = foreign, actionId = "Movement.Sprint", origin = "Direct" })
			local rejected: Types.ActionRequestOutcome = outcome(denied, "Rejected", "ForeignStart")
			assert(rejected.reason == "ActorNotOwned", "ForeignStartReason:" .. tostring(rejected.reason))
		end
	end

	control:FireServer("Mount")
	local mount: ActorTypes.ActorView = viewFor(player, "MountActorId")
	local ride: number? = runtime:Start({ actor = mount, actionId = "Movement.Sprint", origin = "Input" })
	outcome(ride, "Accepted", "DelegatedMountStart")
	outcome(runtime:Interrupt(ride :: number, "ActorSwitched"), "Accepted", "DelegatedMountInterrupt")
	runtime:Retire(ride :: number)
	assert(runtime:_GetRetainedCountForTests() == 0, "OriginalStartsRetainedAfterRetirement")

	return { fireballSequenceId = fireball.sequenceId }
end

local completed: boolean, report: any = pcall(run)
control:FireServer("Done", if completed then report else { failure = tostring(report) })
