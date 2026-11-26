--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local packages: Folder = ReplicatedStorage:WaitForChild("Packages") :: Folder
packages:WaitForChild("KRF")
local KRF = require(ReplicatedStorage.Packages.KRF)

local control: RemoteEvent = ReplicatedStorage:WaitForChild("PresentationTestControl") :: RemoteEvent
local player: Player = Players.LocalPlayer
local started: { number } = {}
local active: { KRF.PresentationContext } = {}
local highlights: { Highlight } = {}
local worldHint: KRF.PresentationContext? = nil
local actorHint: KRF.PresentationContext? = nil
local initial: KRF.ActorView? = nil

local function waitFor(predicate: () -> boolean, reason: string): ()
	local deadline: number = os.clock() + 12

	while not predicate() do
		assert(os.clock() < deadline, reason)
		task.wait()
	end
end

local swordHighlight: KRF.PresentationDefinition = {
	id = "Sword.Swing.Highlight",
	entry = { event = KRF.PresentationEvents.Action.Started, id = "Sword.Swing" },
	create = function(context: KRF.PresentationContext)
		local observation: KRF.PresentationEntryEvent = context.entry
		assert(observation.source == "Action", "Expected Action entry")
		table.insert(started, observation.action.sequenceId)
		local actor: KRF.ActorView = assert(context.actor, "Expected Action origin")
		local model: Model = assert(actor:GetModel(), "Expected streamed native Model")

		local highlight: Highlight = Instance.new("Highlight")
		highlight.Adornee = model
		highlight.Parent = model

		context:Own(function()
			highlight:Destroy()
		end)

		table.insert(active, context)
		table.insert(highlights, highlight)
	end,
}

local worldImpact: KRF.PresentationDefinition = {
	id = "WorldImpact",
	entry = { event = KRF.PresentationEvents.Hint.Received, id = "Impact.World" },
	create = function(context: KRF.PresentationContext)
		local observation: KRF.PresentationEntryEvent = context.entry

		assert(
			observation.source == "Hint" and observation.payload == 21 and context.actor == nil,
			"Incorrect world Hint"
		)

		if worldHint == nil then
			worldHint = context
		else
			context:Finish()
		end
	end,
}

local actorImpact: KRF.PresentationDefinition = {
	id = "ActorImpact",
	entry = { event = KRF.PresentationEvents.Hint.Received, id = "Impact.Actor" },
	create = function(context: KRF.PresentationContext)
		local observation: KRF.PresentationEntryEvent = context.entry

		assert(
			observation.source == "Hint" and observation.payload == 22 and observation.actor == initial,
			"Incorrect Actor Hint"
		)

		actorHint = context
	end,
}

local function run(phase: string, actorId: string): ()
	if phase == "Initial" then
		waitFor(function()
			local view: KRF.ActorView? = KRF.ActorViewRegistry.GetActorViewById(actorId)

			return view ~= nil and view:GetModel() ~= nil
		end, "Initial native actor baseline missing")

		initial = assert(KRF.ActorViewRegistry.GetActorViewById(actorId), "Expected registered ActorView")
		assert(initial:GetDomain("KRF.Actions") == nil and #started == 0, "Initial baseline should omit Actions")
	elseif phase == "Replacement" then
		waitFor(function()
			return initial ~= nil and initial:GetActions():GetAction(1) ~= nil
		end, "Replacement baseline did not add Actions")

		assert(
			KRF.ActorViewRegistry.GetActorViewById(actorId) == initial and #started == 0,
			"Recovery replayed the active Action"
		)
	elseif phase == "Live" then
		waitFor(function()
			return #highlights >= 2 and worldHint ~= nil and actorHint ~= nil
		end, "Presentation missed native Action commits or Hint receipts after recovery")

		assert(#highlights == 2 and active[1] ~= active[2], "Expected two independent instances")
		table.sort(started)
		assert(#started == 2 and started[1] == 2 and started[2] == 3, "Expected live starts only")

		assert(
			highlights[1] ~= highlights[2] and highlights[1].Parent == highlights[2].Parent,
			"Expected distinct Highlights on the same Actor"
		)

		active[1]:Finish()

		waitFor(function()
			return highlights[1].Parent == nil
		end, "Explicit Finish did not destroy the Highlight")

		assert(active[2]:IsActive() and highlights[2].Parent ~= nil, "Finish affected the second instance")
	elseif phase == "Removed" then
		waitFor(function()
			return highlights[2].Parent == nil and actorHint ~= nil and not actorHint:IsActive()
		end, "Actor retirement retained native Highlight or targeted Hint")

		assert(
			not active[2]:IsActive() and worldHint ~= nil and worldHint:IsActive(),
			"Expected only Actor-less instance to survive Actor removal"
		)

		KRF.Client._ResetForTests()
		assert(not worldHint:IsActive(), "Reset left Actor-less Hint active")
	end
end

control.OnClientEvent:Connect(function(phase: string, actorId: string)
	local successful: boolean, failure: any = pcall(run, phase, actorId)
	control:FireServer(phase, if successful then nil else tostring(failure))
end)

waitFor(function()
	return player:GetAttribute("ValidPresentationCatalog") ~= nil
end, "Native role was not assigned")

if player:GetAttribute("ValidPresentationCatalog") == true then
	local initialized, failure = KRF.Client.Init({ presentations = { swordHighlight, worldImpact, actorImpact } })

	control:FireServer(
		"Ready",
		if initialized then nil else if failure ~= nil then failure.reason else "Client.Init failed"
	)
else
	local initialized, failure = KRF.Client.Init({ presentations = { swordHighlight, swordHighlight } })

	local passed: boolean = not initialized
		and failure ~= nil
		and failure.system == "Presentation"
		and failure.reason == "PresentationIdDuplicate"
		and #KRF.ActorViewRegistry.GetAllActorViews() == 0

	control:FireServer("Invalid", if passed then nil else "Invalid Presentation startup was not atomic")
end
