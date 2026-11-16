--!strict
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local packages = ReplicatedStorage:WaitForChild("Packages")
local KRF = require(packages:WaitForChild("KRF"))

local control: RemoteEvent = ReplicatedStorage:WaitForChild("StarterTestControl") :: RemoteEvent
local registry: KRF.ActorViewRegistry = KRF.ActorViewRegistry
local actions: KRF.ClientActionRuntime = KRF.ClientActionRuntime
local localPlayer: Player = Players.LocalPlayer

local TIMEOUT = 20
local SERVER_ONLY_TAG = "TestSecret"
local FOCUS_ROUTE: KRF.RouteKey = { kind = "Input", inputId = "Focus", gesture = "Pressed" }

local previousIds: { string } = {}
local focusStarted: { [string]: boolean } = {}
local focusedAdded: { [string]: boolean } = {}
local leaked: boolean = false
local watching: { [KRF.ActorView]: boolean } = {}

local function waitFor(description: string, predicate: () -> boolean, timeout: number?): ()
	local deadline: number = os.clock() + (timeout or TIMEOUT)

	while not predicate() do
		if os.clock() > deadline then
			error(`Timed out waiting for {description}`, 0)
		end

		task.wait(0.05)
	end
end

local function viewsFor(ids: { string }): { KRF.ActorView }
	local views: { KRF.ActorView } = {}

	waitFor("ActorViews for every player Actor", function()
		table.clear(views)

		for _, id: string in ids do
			local view: KRF.ActorView? = registry.GetActorViewById(id)

			if view == nil then
				return false
			end

			table.insert(views, view)
		end

		return true
	end)

	return views
end

local function ownView(): KRF.ActorView
	local found: KRF.ActorView? = nil

	waitFor("the local character's ActorView", function()
		local character: Model? = localPlayer.Character
		found = if character ~= nil then registry.GetActorViewByModel(character) else nil
		return found ~= nil
	end)

	return found :: KRF.ActorView
end

local function assertNoServerOnlyState(): ()
	assert(not leaked, "A ServerOnly Tag event reached the client")

	for _, view: KRF.ActorView in registry.GetAllActorViews() do
		local tags: KRF.TagsView = view:GetTags()
		assert(
			not tags:HasTag(SERVER_ONLY_TAG) and tags:GetTag(SERVER_ONLY_TAG) == nil,
			"ServerOnly Tag reached the client"
		)

		for _, snapshot: KRF.ActiveTagSnapshot in tags:GetActiveTags() do
			assert(snapshot.tagId ~= SERVER_ONLY_TAG, "ServerOnly Tag listed in TagsView")
		end

		for _, domainId: string in view:GetDomainIds() do
			local domain: KRF.DomainView? = view:GetDomain(domainId)
			local state: any = if domain ~= nil then domain:GetState() else nil
			local encoded: string = HttpService:JSONEncode(state)
			assert(not string.find(encoded, SERVER_ONLY_TAG, 1, true), `ServerOnly Tag found in domain {domainId}`)
		end
	end
end

local function watchView(view: KRF.ActorView): ()
	if watching[view] then
		return
	end

	watching[view] = true

	local id: string = view:GetId()
	local tags: KRF.TagsView = view:GetTags()

	view:GetActions().OnActionStarted:Connect(function(snapshot: KRF.ActionSnapshot)
		if snapshot.actionId == "Focus" then
			focusStarted[id] = true
		end
	end)

	for _, event: KRF.Event<string> in { tags.OnTagAdded, tags.OnTagRefreshed, tags.OnTagRemoved, tags.OnTagExpired } do
		event:Connect(function(tagId: string)
			if tagId == "Focused" then
				focusedAdded[id] = true
			elseif tagId == SERVER_ONLY_TAG then
				leaked = true
			end
		end)
	end
end

local function assertControlsOwnView(): ()
	local view: KRF.ActorView = ownView()

	waitFor("Controls to take the local character's ActorView", function()
		return actions.GetControlledActor() == view
	end)

	local route = actions.GetEffectiveRoute(view, FOCUS_ROUTE) :: any
	assert(route ~= nil and route.status == "Mapped" and route.actionId == "Focus", "F is routed to Focus")
end

local function watch(payload: { actorIds: { string } }): ()
	local again: boolean, failure: KRF.ClientStartupFailure? = KRF.Client.Init()
	assert(not again and failure ~= nil, "Startup.client.luau owns the one Client.Init")

	registry.OnActorViewAdded:Connect(watchView)

	for _, view: KRF.ActorView in viewsFor(payload.actorIds) do
		watchView(view)
	end

	assertControlsOwnView()
end

local function press(payload: { hold: number }): ()
	assertControlsOwnView()

	local container: Instance = localPlayer:WaitForChild("PlayerScripts"):WaitForChild("KRFInputs", TIMEOUT) :: Instance
	local action: Instance = (container:WaitForChild("Gameplay", TIMEOUT) :: Instance):WaitForChild(
			"Focus",
			TIMEOUT
		) :: Instance
	local driver: InputBinding = Instance.new("InputBinding")
	driver.Type = Enum.InputBindingType.Scriptable
	driver.Parent = action
	task.wait()

	driver:Fire(true)
	task.delay(payload.hold, function()
		driver:Fire(false)
		driver:Destroy()
	end)
end

local function observe(payload: { actorIds: { string }, exampleRemoved: boolean? }): ()
	local views: { KRF.ActorView } = viewsFor(payload.actorIds)
	assert(#registry.GetAllActorViews() == #payload.actorIds, "The client sees every player Actor")
	previousIds = payload.actorIds

	if payload.exampleRemoved then
		local again: boolean = KRF.Client.Init()
		assert(not again, "Startup.client.luau owns the one Client.Init")
		assert(localPlayer.PlayerScripts:FindFirstChild("KRFInputs") == nil, "No input is installed without Controls")
		assert(localPlayer.PlayerGui:FindFirstChild("EnergyDisplay") == nil, "No Energy display without the example")
		return
	end

	waitFor("Focus and Focused on every visible Actor", function()
		for _, id: string in payload.actorIds do
			if not focusStarted[id] or not focusedAdded[id] then
				return false
			end
		end

		return true
	end)

	for _, view: KRF.ActorView in views do
		local resources: KRF.ResourcesView = view:GetResources()
		assert(resources:GetMax("Energy") == 100, "Energy max replicates")
		assert((resources:GetCurrent("Energy") or 0) >= 10, "Regenerated Energy replicates to every client")
	end

	local own: KRF.ActorView = ownView()
	local label: TextLabel = localPlayer.PlayerGui:WaitForChild("EnergyDisplay"):WaitForChild("Energy") :: TextLabel
	waitFor("the Energy display to show the local Actor's Energy", function()
		local current: number = math.floor(own:GetResources():GetCurrent("Energy") or 0)
		return label.Text == `Energy {current}/100`
	end)

	assertNoServerOnlyState()
end

local function respawned(payload: { actorIds: { string } }): ()
	viewsFor(payload.actorIds)

	for _, id: string in previousIds do
		if not table.find(payload.actorIds, id) then
			waitFor("the respawned character's old view to be removed", function()
				return registry.GetActorViewById(id) == nil
			end)
		end
	end

	assert(#registry.GetAllActorViews() == #payload.actorIds, "Old views are released")
	assertControlsOwnView()
	assertNoServerOnlyState()
	previousIds = payload.actorIds
end

local function published(payload: { actorId: string }): ()
	local view: KRF.ActorView = viewsFor({ payload.actorId })[1]
	assert(view:GetModel() == nil, "The character has not replicated yet")
	assert(actions.GetControlledActor() == nil, "Nothing is controlled before Controls starts")

	local controls =
		require(localPlayer:WaitForChild("PlayerScripts"):WaitForChild("Game"):WaitForChild("Controls")) :: any
	controls.Start()
end

local function bound(): ()
	assertControlsOwnView()
end

local PHASES: { [string]: (any) -> () } = {
	Watch = watch,
	Published = published,
	Bound = bound,
	Observe = observe,
	Respawned = respawned,
}

control.OnClientEvent:Connect(function(phase: string, encoded: string)
	local handler = PHASES[phase] or (if string.sub(phase, 1, 5) == "Press" then press else nil)

	if handler == nil then
		return
	end

	local ok: boolean, failure: any = pcall(handler, HttpService:JSONDecode(encoded))
	control:FireServer(phase, ok, if ok then nil else tostring(failure))
end)
