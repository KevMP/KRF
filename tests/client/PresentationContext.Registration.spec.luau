--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Presentation.types)
local Events = require(KRF.client.Presentation.PresentationEvents)
local Instances = require(KRF.client.Presentation.utils.PresentationInstance)
local Subscriptions = require(KRF.client.Presentation.utils.PresentationSubscriptions)
local ActorTypes = require(KRF.client.Actor.types)
local ActorView = require(KRF.client.Actor.ActorView)
local DomainView = require(KRF.client.Actor.DomainView)
local Actors = require(KRF.client.Actor.utils.ActorViewRegistryState)
local SignalTypes = require(KRF.shared.Signal.types)
local Hints = require(KRF.client.Networking.utils.HintRuntimeState)

local contexts: { Types.PresentationContext } = {}
local owners: { ActorTypes.ActorViewOwner } = {}

local environment: Types.PresentationSubscriptionEnvironment = {
	IsEligible = function(actor: ActorTypes.ActorView): boolean
		return Actors.IsCurrent(actor) and not Actors.IsInvalidating(actor) and actor:IsAvailable()
	end,
	TrackActor = function(): () -> ()
		return function(): () end
	end,
	IsStateReady = function(): boolean
		return false
	end,
	ObserveReadiness = function(): () -> ()
		return function(): () end
	end,
}

afterEach(function()
	for _, context in contexts do
		context:Finish()
	end

	table.clear(contexts)
	Actors.Reset()

	for _, owner in owners do
		owner:Destroy()
	end

	table.clear(owners)
end)

local function contextFor(entry: Types.PresentationEntry): Types.PresentationContext
	local context: Types.PresentationContext = Instances.New({
		id = "Registration",
		entry = { event = Events.Hint.Received, id = "Origin" },
		create = function(): () end,
	}, entry, environment, function(): () end)

	table.insert(contexts, context)

	return context
end

it("rejects malformed live registrations with actionable errors and leaves the instance usable", function()
	local context: Types.PresentationContext =
		contextFor(table.freeze({ source = "Hint" :: "Hint", event = "Received" :: "Received", hintId = "Origin" }))

	-- Invalid calls intentionally cross the public type boundary to verify runtime validation.
	local unsafe: any = context
	local callback = function(): () end

	local cases: { { arguments: { any }, reason: string } } = {
		{ arguments = { { source = "Hint", event = "Received" }, callback }, reason = "UnknownEventDescriptor" },
		{ arguments = { Events.Hint.Received }, reason = "InvalidArguments" },
		{ arguments = { Events.Hint.Received, "Origin", callback, "extra" }, reason = "InvalidArguments" },
		{ arguments = { Events.Hint.Received, "Origin", 5 }, reason = "CallbackInvalid" },
		{ arguments = { Events.Hint.Received, "", callback }, reason = "IdInvalid" },
		{ arguments = { Events.Hint.Received, 7, callback }, reason = "FilterInvalid" },
		{ arguments = { Events.Hint.Received, setmetatable({}, {}), callback }, reason = "FilterInvalid" },
		{ arguments = { Events.Hint.Received, { id = "Origin", scope = "All" }, callback }, reason = "ScopeInvalid" },
		{
			arguments = { Events.Hint.Received, { id = "Origin", extra = true }, callback },
			reason = "ScopeFieldUnknown",
		},
		{ arguments = { Events.Hint.Received, { scope = "Any" }, callback }, reason = "IdInvalid" },
		{ arguments = { Events.Tag.Added, { id = "Origin", scope = "Any" }, callback }, reason = "ScopeInvalid" },
		{
			arguments = { Events.Hint.Received, { id = "Origin", actor = {}, scope = "Any" }, callback },
			reason = "ScopeInvalid",
		},
		{ arguments = { Events.Tag.Added, { id = "Origin", actor = {} }, callback }, reason = "ActorUnavailable" },
		{ arguments = { Events.Tag.Added, "Origin", callback }, reason = "ActorMissing" },
		{ arguments = { Events.Tag.Added, callback }, reason = "OriginIdMissing" },
		{ arguments = { Events.Resource.Changed, callback }, reason = "OriginIdMissing" },
		{ arguments = { Events.Action.Ended, callback }, reason = "OriginActionMissing" },
	}

	for _, case in cases do
		local success: boolean, failure: any = pcall(function()
			unsafe:On(table.unpack(case.arguments))
		end)

		expect(success).toBe(false)
		expect(string.find(tostring(failure), "id=Registration On: " .. case.reason, 1, true) ~= nil).toBe(true)
	end

	local received: number = 0

	context:On(Events.Hint.Received, function()
		received += 1
	end)

	Hints.Notify({ hintId = "Origin" })
	task.wait()
	expect(received).toBe(1)
	expect(context:IsActive()).toBe(true)
end)

it("returns an inert ordinary Connection after retirement even for malformed calls", function()
	local context: Types.PresentationContext = contextFor({ source = "Hint", event = "Received", hintId = "Origin" })
	context:Finish()
	local unsafe: any = context
	local connection: SignalTypes.Connection = unsafe:On(nil)
	connection:Disconnect()
	connection:Disconnect()
	expect(context:IsActive()).toBe(false)
end)

it("bounds simultaneous subscriptions, frees slots on disconnect and owns dropped handles", function()
	local context: Types.PresentationContext = contextFor({ source = "Hint", event = "Received", hintId = "Origin" })
	local received: number = 0

	local function record(): ()
		received += 1
	end

	local first: SignalTypes.Connection = context:On(Events.Hint.Received, record)

	for _ = 2, 64 do
		context:On(Events.Hint.Received, record)
	end

	local success: boolean, failure: any = pcall(function()
		context:On(Events.Hint.Received, record)
	end)

	expect(success).toBe(false)
	expect(string.find(tostring(failure), "SubscriptionLimit", 1, true) ~= nil).toBe(true)
	first:Disconnect()
	first:Disconnect()
	context:On(Events.Hint.Received, record)
	Hints.Notify({ hintId = "Origin" })
	task.wait()
	expect(received).toBe(64)
	context:Finish()
	Hints.Notify({ hintId = "Origin" })
	task.wait()
	expect(received).toBe(64)
end)

it("reads the private Action association on delivery independently of entry family or subscription time", function()
	local actions: ActorTypes.DomainViewOwner =
		assert(DomainView.new("KRF.Actions", {}, { "Started", "Ended", "Interrupted" }))

	local owner: ActorTypes.ActorViewOwner = assert(ActorView.new("Association", nil, { ["KRF.Actions"] = actions }))
	table.insert(owners, owner)
	assert(Actors.Install(owner.view))
	local association: Types.PresentationActionAssociation? = { actor = owner.view, actionId = "Swing" }
	local origin: Types.HintEntryEvent = { source = "Hint", event = "Received", actor = owner.view, hintId = "Origin" }
	local context: Types.PresentationContext = contextFor(origin)
	local received: { number } = {}

	local on, _watch, stop = Subscriptions.New("Association", origin, {
		IsActive = function(): boolean
			return context:IsActive()
		end,
		GetActionAssociation = function(): Types.PresentationActionAssociation?
			return association
		end,
		GetPrediction = function(): Types.PresentationPredictionLink?
			return nil
		end,
		Fail = function(): ()
			error("Unexpected callback failure")
		end,
	}, environment)

	local connection: SignalTypes.Connection = on(context, Events.Action.Ended, function(event: Types.ActionEntryEvent)
		table.insert(received, event.action.sequenceId)
	end)

	actions:FireEvent("Ended", table.freeze({ actionId = "Swing", sequenceId = 7 }))
	task.wait()
	expect(received).toEqual({})
	association = { actor = owner.view, actionId = "Swing", sequenceId = 8 }
	actions:FireEvent("Ended", table.freeze({ actionId = "Swing", sequenceId = 7 }))
	actions:FireEvent("Ended", table.freeze({ actionId = "Swing", sequenceId = 8 }))
	task.wait()
	expect(received).toEqual({ 8 })
	association = nil
	actions:FireEvent("Ended", table.freeze({ actionId = "Swing", sequenceId = 8 }))
	task.wait()
	expect(received).toEqual({ 8 })
	connection:Disconnect()
	stop()
end)
