--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local packages: Folder = ReplicatedStorage:WaitForChild("Packages") :: Folder
packages:WaitForChild("KRF")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Actor.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Client = require(KRF.client)
local Registry: Types.ActorViewRegistry = require(KRF.client.Actor.ActorViewRegistry)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("ActorViewTestControl") :: RemoteEvent

-- Deliberately no Native/InstallConsumers overrides, Consumer.Install calls,
-- fake transports, fake Players or direct N4/N5 delivery callbacks.
local view: Types.ActorView? = nil
local domain: Types.DomainView? = nil
local private: Types.DomainView? = nil
local originalModel: Model? = nil
local changes: { Types.DomainChange } = {}
local semantic: { number } = {}
local removed: number = 0
local terminal: { string } = {}
local failed: boolean = false
local connections: { SignalTypes.Connection } = {}

local function report(phase: string, failure: string?): ()
	control:FireServer(buffer.fromstring(HttpService:JSONEncode({ phase = phase, failure = failure })))
end

local function waitFor(predicate: () -> boolean, reason: string): ()
	local deadline: number = os.clock() + 22
	while not predicate() do
		assert(os.clock() < deadline, reason)
		task.wait(0.02)
	end
end

local function checkVisibility(owned: boolean): ()
	assert(view ~= nil, "Expected ActorView")
	local current: Types.DomainView? = view:GetDomain("Game.NativeOwner")
	if owned then
		assert(current ~= nil and current:GetState().secret == "owner-only", "Owner did not receive private truth")
	else
		assert(
			current == nil and table.find(view:GetDomainIds(), "Game.NativeOwner") == nil,
			"Private Owner truth leaked"
		)
	end
end

local function runPhase(message: any): ()
	local phase: string = message.phase
	local actorId: string = message.actorId
	local owned: boolean = message.owner
	if phase == "Initial" then
		waitFor(function(): boolean
			return Registry.GetActorViewById(actorId) ~= nil
		end, "Complete native baseline did not automatically create an ActorView")
		view = Registry.GetActorViewById(actorId)
		assert(view ~= nil, "Expected public ActorView")
		domain = view:GetDomain("Game.NativeState")
		assert(domain ~= nil and domain:GetState().current == 10, "Initial truth differs")
		waitFor(function(): boolean
			return (view :: Types.ActorView):GetModel() ~= nil
		end, "Native Model did not bind")
		originalModel = view:GetModel()
		assert(
			originalModel ~= nil and Registry.GetActorViewByModel(originalModel) == view,
			"Native Model index differs"
		)
		checkVisibility(owned)
		private = view:GetDomain("Game.NativeOwner")
		table.insert(
			connections,
			view.OnDomainsChanged:Connect(function(change: Types.DomainMembershipChange)
				assert(
					view ~= nil and not view:IsAvailable(),
					"Native membership did not reflect terminal invalidation"
				)
				assert(#view:GetDomainIds() == 0 and domain ~= nil and domain:GetState() == nil, "Halt was not atomic")
				assert(table.isfrozen(change) and table.isfrozen(change.removed), "Mutable native membership payload")
				if private ~= nil then
					assert(private:GetState() == nil, "Halt retained private Owner truth")
				end
				table.insert(terminal, "Domains")
			end)
		)
		table.insert(
			connections,
			view.OnUnavailable:Connect(function()
				assert(view ~= nil and not view:IsAvailable(), "Native terminal event preceded invalidation")
				table.insert(terminal, "Unavailable")
			end)
		)
		table.insert(
			connections,
			domain.OnChanged:Connect(function(change: Types.DomainChange)
				table.insert(changes, change)
			end)
		)
		local event: SignalTypes.Event<any>? = domain:GetEvent("Changed")
		assert(event ~= nil, "Expected declared semantic event")
		table.insert(
			connections,
			event:Connect(function(payload: number)
				table.insert(semantic, payload)
			end)
		)
		table.insert(
			connections,
			Registry.OnActorViewRemoving:Connect(function(removing: Types.ActorView)
				if removing == view then
					removed += 1
				end
			end)
		)
	elseif phase == "Live" then
		assert(domain ~= nil, "Expected retained domain")
		waitFor(function(): boolean
			return (domain :: Types.DomainView):GetState().current == 20 and #semantic == 1 and #changes >= 1
		end, "Native live state/event did not arrive")
		assert(changes[1].source == "Commit" and semantic[1] == 20, "Live publication semantics differ")
		checkVisibility(owned)
	elseif phase == "Recovery" then
		assert(domain ~= nil, "Expected retained domain")
		waitFor(function(): boolean
			if (domain :: Types.DomainView):GetState().current ~= 30 then
				return false
			end
			if not owned then
				return true
			end
			for _, change: Types.DomainChange in changes do
				if change.source == "Baseline" and change.current.current == 30 then
					return true
				end
			end
			return false
		end, "Real native resync did not restore replacement truth")
		assert(Registry.GetActorViewById(actorId) == view, "Resync replaced ActorView identity")
		assert((view :: Types.ActorView):GetDomain("Game.NativeState") == domain, "Resync replaced retained DomainView")
		assert(#semantic == 1, "Replacement replayed semantic history")
		assert((view :: Types.ActorView):IsAvailable(), "Recoverable desync terminally invalidated the view")
		checkVisibility(owned)
	elseif phase == "Halt" then
		assert(view ~= nil, "Expected retained ActorView")
		waitFor(function(): boolean
			return not (view :: Types.ActorView):IsAvailable() and #terminal == 2
		end, "Real server halt did not publish terminal invalidation")
		assert(terminal[1] == "Domains" and terminal[2] == "Unavailable", "Native terminal event order differs")
		assert(Registry.GetActorViewById(actorId) == view, "Terminal halt removed Actor identity")
		assert(view:GetModel() == originalModel, "Terminal halt changed Model binding")
		assert(removed == 0, "Terminal halt synthesized Actor removal")
	elseif phase == "Removed" then
		waitFor(function(): boolean
			return Registry.GetActorViewById(actorId) == nil and removed == 1
		end, "Authoritative native removal did not clean the view once")
		assert(
			originalModel ~= nil and Registry.GetActorViewByModel(originalModel) == nil,
			"Removed Model mapping remained"
		)
		assert(domain ~= nil, "Expected stale domain reference")
		assert(not pcall(function()
			(domain :: Types.DomainView).OnChanged:Connect(function(_change: Types.DomainChange) end)
		end), "Removed domain signals remain live")
		if private ~= nil then
			assert(private:GetState() == nil, "Removed Actor retained private Owner truth")
		end
	elseif phase == "Respawn" then
		local previous: Types.ActorView? = view
		waitFor(function(): boolean
			return Registry.GetActorViewById(actorId) ~= nil
		end, "Respawn did not create a distinct ActorView")
		view = Registry.GetActorViewById(actorId)
		assert(view ~= nil and view ~= previous, "Respawn reused a retired ActorView")
		domain = view:GetDomain("Game.NativeState")
		assert(domain ~= nil and domain:GetState().current == 70, "Respawn baseline truth differs")
		checkVisibility(owned)
		if owned then
			assert(view:GetDomain("Game.NativeOwner") ~= private, "Respawn revived a retired private DomainView")
		end
		private = view:GetDomain("Game.NativeOwner")
	elseif phase == "Reset" then
		Client._ResetForTests()
		Client._ResetForTests()
		assert(#Registry.GetAllActorViews() == 0, "Native client teardown retained views")
		assert(domain ~= nil and domain:GetState() == nil, "Native reset retained live domain truth")
		if private ~= nil then
			assert(private:GetState() == nil, "Native reset retained private Owner truth")
		end
		for _, connection: SignalTypes.Connection in connections do
			connection:Disconnect()
		end
	else
		error("Unexpected native N5 phase: " .. phase, 0)
	end
	report(phase, nil)
end

control.OnClientEvent:Connect(function(payload: any)
	if failed then
		return
	end
	local completed: boolean, reason: any = pcall(function()
		assert(typeof(payload) == "buffer", "Expected buffer phase message")
		runPhase(HttpService:JSONDecode(buffer.tostring(payload)))
	end)
	if not completed then
		failed = true
		report("Failed", tostring(reason))
	end
end)

local initialized: boolean, failure: Client.StartupFailure? = Client.Init()
if initialized then
	assert(#Registry.GetAllActorViews() == 0, "Init raced premature Actor creation")
	report("Ready", nil)
else
	report("Ready", if failure ~= nil then failure.reason else "Native Client.Init failed")
end
