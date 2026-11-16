--!strict
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StudioTestService = game:GetService("StudioTestService")

local KRF = require(ReplicatedStorage.Packages.KRF)
local PlayerActors = require(ServerScriptService:WaitForChild("Game"):WaitForChild("PlayerActors"))

local control: RemoteEvent = ReplicatedStorage:WaitForChild("StarterTestControl") :: RemoteEvent
local scenario: string = control:GetAttribute("Scenario") :: string

local CLIENTS = 2
local HOLD_SECONDS = 1.5
local TIMEOUT = 45

local phase: string = "Setup"
local completed: { string } = {}
local finished: boolean = false
local reports: { [Player]: { ok: boolean, detail: string? } } = {}

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished = true
	StudioTestService:EndTest({
		success = success,
		reason = reason,
		scenario = scenario,
		phase = phase,
		completed = completed,
	})
end

local function waitFor(description: string, predicate: () -> boolean, timeout: number?): ()
	local deadline: number = os.clock() + (timeout or TIMEOUT)

	while not predicate() do
		if os.clock() > deadline then
			error(`Timed out waiting for {description}`, 0)
		end

		task.wait(0.05)
	end
end

local function step(name: string, body: () -> ()): ()
	phase = name
	body()
	table.insert(completed, name)
end

control.OnServerEvent:Connect(function(player: Player, reportedPhase: unknown, ok: unknown, detail: unknown)
	if reportedPhase == phase and type(ok) == "boolean" then
		reports[player] = { ok = ok, detail = if type(detail) == "string" then detail else nil }
	end
end)

local function askClients(name: string, payload: { [string]: any }, expected: { Player }): ()
	phase = name
	reports = {}

	for _, player: Player in expected do
		control:FireClient(player, name, HttpService:JSONEncode(payload))
	end

	waitFor(`client reports for {name}`, function()
		for _, player: Player in expected do
			if reports[player] == nil then
				return false
			end
		end

		return true
	end)

	for _, player: Player in expected do
		local report = reports[player]
		assert(report.ok, `{player.Name} failed {name}: {report.detail or "no detail"}`)
	end

	table.insert(completed, name)
end

local function players(): { Player }
	local current: { Player } = Players:GetPlayers()
	table.sort(current, function(left: Player, right: Player): boolean
		return left.UserId < right.UserId
	end)

	return current
end

local function actorOf(player: Player): KRF.Actor
	local actor: KRF.Actor? = PlayerActors.GetActor(player)
	assert(actor ~= nil, `{player.Name} has no Actor`)

	return actor
end

local function controller<T>(actor: KRF.Actor, key: string): T
	local found = actor:GetController(key)
	assert(found ~= nil, `Actor is missing {key}`)

	return (found :: any) :: T
end

local function waitForActors(expected: { Player }): ()
	waitFor("player characters registered as Actors", function()
		for _, player: Player in expected do
			if player.Character == nil or PlayerActors.GetActor(player) == nil then
				return false
			end
		end

		return true
	end)
end

local function actorIds(expected: { Player }): { string }
	local ids: { string } = {}

	for _, player: Player in expected do
		table.insert(ids, actorOf(player):GetId())
	end

	return ids
end

local function liveActorCount(): number
	local count: number = 0

	for _, player: Player in Players:GetPlayers() do
		if PlayerActors.GetActor(player) ~= nil then
			count += 1
		end
	end

	return count
end

local function startupFailureLogged(): boolean
	for _, entry in LogService:GetLogHistory() do
		if string.find(entry.message, "KRF server startup failed (", 1, true) then
			return true
		end
	end

	return false
end

local function pressFocus(player: Player): ()
	local actor: KRF.Actor = actorOf(player)
	local actions: KRF.ActionController = controller(actor, "ActionController")
	local resources: KRF.ResourceController = controller(actor, "ResourceController")
	local tags: KRF.TagController = controller(actor, "TagController")
	local energyBefore: number = resources:GetCurrent("Energy") or 0
	local started: boolean = false
	local ended: boolean = false
	local startedAt: number = 0

	local startedConnection = actions.OnActionStarted:Connect(function(event: KRF.ActionLifecycleEvent)
		if event.actionId == "Focus" and not started then
			started = true
			startedAt = os.clock()
		end
	end)

	local endedConnection = actions.OnActionEnded:Connect(function(event: KRF.ActionLifecycleEvent)
		if event.actionId == "Focus" and started then
			ended = true
		end
	end)

	askClients(`Press{player.UserId}`, { hold = HOLD_SECONDS }, { player })
	waitFor("the pressed Focus to start", function()
		return started
	end, 10)

	assert(tags:HasTag("Focused"), "Focus applies Focused while active")
	local overlapping: KRF.ActionRequestResult = actions:RequestAction("Focus")
	assert(not overlapping.accepted, "Focused blocks a second Focus")

	task.wait(1)
	assert((resources:GetCurrent("Energy") or 0) > energyBefore, "Focused regenerates Energy while Focus is held")
	assert(not ended, "Focus stays active while the key is held")

	waitFor("releasing the key to end Focus", function()
		return ended
	end, 10)
	local heldFor: number = os.clock() - startedAt

	startedConnection:Disconnect()
	endedConnection:Disconnect()

	local channelled: number = (resources:GetCurrent("Energy") or 0) - energyBefore
	assert(heldFor >= HOLD_SECONDS - 0.3 and heldFor <= HOLD_SECONDS + 1, `Focus ends on release, held {heldFor}s`)
	assert(
		math.abs(channelled - 10 * heldFor) <= 3,
		`Focus regenerates 10 Energy per second, got {channelled} in {heldFor}s`
	)
	assert(not tags:HasTag("Focused"), "Focus removes Focused when it ends")

	local settled: number = resources:GetCurrent("Energy") or 0
	task.wait(0.5)
	assert(resources:GetCurrent("Energy") == settled, "Energy has no regeneration outside Focus")
end

local function runStarter(): ()
	local everyone: { Player } = {}

	step("Join", function()
		waitFor("two players", function()
			return #Players:GetPlayers() == CLIENTS
		end)
		everyone = players()
		waitForActors(everyone)

		local first: KRF.Actor, second: KRF.Actor = actorOf(everyone[1]), actorOf(everyone[2])
		assert(first ~= second and first:GetId() ~= second:GetId(), "Each player needs a distinct Actor")

		for _, player: Player in everyone do
			local actor: KRF.Actor = actorOf(player)
			assert(actor.model == player.Character, "The Actor is bound to the current character")
			assert(KRF.ActorRegistry.GetActorByModel(player.Character :: Model) == actor, "KRF knows the binding")

			for _, key: string in { "TagController", "PropertyController", "ResourceController", "ActionController" } do
				controller(actor, key)
			end

			local actions: KRF.ActionController = controller(actor, "ActionController")
			assert(actions:IsActionGranted("Focus"), "Focus is auto-granted")
		end

		local again: boolean, failure: KRF.ServerStartupFailure? = KRF.Server.Init({})
		assert(
			not again and failure ~= nil and failure.reason == "ServerInitAlreadyAttempted",
			"Startup owns the one Init"
		)
		assert(not startupFailureLogged(), "Startup must succeed")

		for _, player: Player in everyone do
			local tags: KRF.TagController = controller(actorOf(player), "TagController")
			assert(tags:AddTag("TestSecret"))
		end
	end)

	askClients("Watch", { actorIds = actorIds(everyone) }, everyone)

	step("Input", function()
		for _, player: Player in everyone do
			pressFocus(player)
		end
	end)

	askClients("Observe", { actorIds = actorIds(everyone) }, everyone)

	step("Respawn", function()
		local player: Player = everyone[1]
		local before: KRF.Actor = actorOf(player)
		local oldCharacter: Model = player.Character :: Model

		player:LoadCharacter()
		waitFor("the respawned character's Actor", function()
			local current: KRF.Actor? = PlayerActors.GetActor(player)
			return current ~= nil and current ~= before
		end)

		local after: KRF.Actor = actorOf(player)
		assert(not before.enabled, "The previous Actor is unregistered")
		assert(after:GetId() ~= before:GetId(), "A respawn creates a new Actor identity")
		assert(KRF.ActorRegistry.GetActorByModel(oldCharacter) == nil, "The old character is unbound")
		assert(liveActorCount() == CLIENTS, "No stale or duplicate Actors after respawn")

		local duplicate: KRF.Actor? = KRF.ActorRuntime.RegisterActor(player.Character :: Model)
		assert(duplicate == nil, "A character cannot be registered twice")
		assert(actorOf(player) == after, "A rejected duplicate leaves the Actor in place")
	end)

	askClients("Respawned", { actorIds = actorIds(everyone) }, everyone)

	step("InputAfterRespawn", function()
		pressFocus(everyone[1])
	end)

	step("CharacterDestroyed", function()
		local player: Player = everyone[1]
		local actor: KRF.Actor = actorOf(player)
		local character: Model = player.Character :: Model

		character:Destroy()
		waitFor("KRF to unregister a destroyed character", function()
			return not actor.enabled and PlayerActors.GetActor(player) == nil
		end)

		player:LoadCharacter()
		waitForActors(everyone)
		assert(liveActorCount() == CLIENTS, "The reloaded character registers")
	end)

	step("Leave", function()
		local leaving: Player = everyone[2]
		local actor: KRF.Actor = actorOf(leaving)

		leaving:Kick("Starter test: player leave")
		waitFor("the departed player's Actor to unregister", function()
			return not actor.enabled
		end)
		assert(PlayerActors.GetActor(everyone[1]) ~= nil, "Other players keep their Actors")
	end)
end

local function runExampleRemoved(): ()
	local everyone: { Player } = {}

	step("Join", function()
		waitFor("two players", function()
			return #Players:GetPlayers() == CLIENTS
		end)
		everyone = players()
		waitForActors(everyone)
		assert(not startupFailureLogged(), "Startup must succeed without the example")
	end)

	askClients("Observe", { actorIds = actorIds(everyone), exampleRemoved = true }, everyone)
end

local function runInvalidDefinitions(): ()
	step("Rejected", function()
		waitFor("two players with characters", function()
			if #Players:GetPlayers() ~= CLIENTS then
				return false
			end

			for _, player: Player in Players:GetPlayers() do
				if player.Character == nil then
					return false
				end
			end

			return true
		end)

		waitFor("the startup failure", startupFailureLogged, 10)
		task.wait(2)

		for _, player: Player in Players:GetPlayers() do
			assert(
				KRF.ActorRegistry.GetActorByModel(player.Character :: Model) == nil,
				"No Actor after a failed startup"
			)
		end

		assert(liveActorCount() == 0, "PlayerActors never started")
	end)
end

local SCENARIOS: { [string]: () -> () } = {
	starter = runStarter,
	["example-removed"] = runExampleRemoved,
	["invalid-definitions"] = runInvalidDefinitions,
}

task.spawn(function()
	local run = SCENARIOS[scenario]
	local ok: boolean, failure: any = pcall(function()
		assert(run ~= nil, `Unknown scenario {scenario}`)
		run()
	end)

	finish(ok, if ok then nil else tostring(failure))
end)
