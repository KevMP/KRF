--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach

local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local Server = require(KRF.server)
local ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local ActorRegistry = require(KRF.server.Actor.ActorRegistry)
local TagControllerModule = require(KRF.server.Tags.TagController)
local TagRegistry = require(KRF.server.Tags.TagRegistry)
local PropertyTypes = require(KRF.server.Property.types)

type ActionDefinition = ActionTypes.ActionDefinition
type ActionController = ActionTypes.ActionController
type Actor = ActorTypes.Actor
type TagController = TagTypes.TagController
type TagDefinition = TagTypes.TagDefinition

local actors: { Actor } = {}
local models: { Model } = {}

beforeEach(function()
	Server._ResetForTests()
	TagControllerModule._setAutomaticSteppingEnabledForTests(false)
	actors = {}
	models = {}
end)

afterEach(function()
	for _, actor: Actor in actors do
		if ActorRegistry.GetActorById(actor:GetId()) ~= nil then
			ActorRuntime.UnregisterActor(actor, "TestCleanup")
		end
	end
	for _, model: Model in models do
		model:Destroy()
	end
	TagControllerModule._setAutomaticSteppingEnabledForTests(true)
	Server._ResetForTests()
end)

local function initialize(definitions: { ActionDefinition }, tags: { TagDefinition }): ()
	local factories: { ActionTypes.ActionFactory } = {}
	for _, definition: ActionDefinition in definitions do
		local source: ActionDefinition = definition
		table.insert(factories, function(): ActionDefinition
			return table.clone(source)
		end)
	end
	local started: boolean, failure = Server.Init({ actions = factories, tags = tags })
	expect(started).toBe(true)
	expect(failure).toBeNil()
end

local function registerActor(): (Actor, ActionController, TagController)
	local model: Model = Instance.new("Model")
	model.Parent = workspace
	table.insert(models, model)
	local actor: Actor?, reason: string? = ActorRuntime.RegisterActor(model)
	expect(reason).toBeNil()
	local registered: Actor = actor :: Actor
	table.insert(actors, registered)
	local actions: ActionController = registered:GetController("ActionController") :: ActionController
	local tags: TagController = registered:GetController("TagController") :: TagController
	expect(actions).never.toBeNil()
	expect(tags).never.toBeNil()
	return registered, actions, tags
end

local function tag(id: string, duplicateBehavior: "Stack" | "Refresh" | "Ignore"): TagDefinition
	return { id = id, duplicateBehavior = duplicateBehavior, visibility = "ServerOnly" :: ActionTypes.ActionVisibility }
end

it("issues Started before a Tag listener synchronously preempts the incoming Action and skips its onStart", function()
	local order: { string } = {}
	initialize({
		{
			id = "Incoming",
			visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Replacement" },
			activeTags = { "Active" },
			appliedTags = { "Applied" },
			onStart = function()
				table.insert(order, "incoming hook")
			end,
			onInterrupt = function()
				table.insert(order, "interrupt hook")
			end,
		},
		{
			id = "Replacement",
			visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
			autoGrant = true,
			locks = { "Hands" },
			activeTags = { "ReplacementTag" },
			onStart = function()
				table.insert(order, "replacement hook")
			end,
		},
	}, { tag("Active", "Stack"), tag("Applied", "Stack"), tag("ReplacementTag", "Stack") })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	local nested: ActionTypes.ActionRequestResult? = nil
	actions.OnActionStarted:Connect(function(event: ActionTypes.ActionLifecycleEvent)
		table.insert(order, "Started " .. event.actionId)
	end)
	actions.OnActionInterrupted:Connect(function(event: ActionTypes.ActionInterruptedEvent)
		table.insert(order, "Interrupted " .. event.actionId)
	end)
	tags.OnTagAdded:Connect(function(_owner: Actor, tagId: string)
		if tagId == "Active" then
			nested = actions:RequestAction("Replacement")
			table.insert(order, "nested returned")
		elseif tagId == "ReplacementTag" then
			table.insert(order, "replacement tag")
		end
	end)
	expect(actions:RequestAction("Incoming")).toEqual({ accepted = true, sequenceId = 1 })
	expect(nested).toEqual({ accepted = true, sequenceId = 2 })
	expect(order).toEqual({
		"Started Incoming",
		"Interrupted Incoming",
		"Started Replacement",
		"replacement tag",
		"interrupt hook",
		"replacement hook",
		"nested returned",
	})
	expect(tags:HasTag("Active")).toBe(false)
	expect(tags:HasTag("Applied")).toBe(true)
	expect(tags:HasTag("ReplacementTag")).toBe(true)
	local ended: boolean, reason: string? = actions:EndAction(1)
	expect(ended).toBe(false)
	expect(reason).toBe("ActionInstanceNotActive")
end)

it("issues Started exactly once when a preempted owner's signal listener preempts the incoming Action", function()
	local order: { string } = {}
	initialize({
		{
			id = "Owner",
			visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Incoming" },
		},
		{
			id = "Incoming",
			visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Replacement" },
			activeTags = { "Active" },
			onStart = function()
				table.insert(order, "incoming hook")
			end,
		},
		{
			id = "Replacement",
			visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
			autoGrant = true,
			locks = { "Hands" },
		},
	}, { tag("Active", "Stack") })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect(actions:RequestAction("Owner")).toEqual({ accepted = true, sequenceId = 1 })
	local nested: ActionTypes.ActionRequestResult? = nil
	actions.OnActionStarted:Connect(function(event: ActionTypes.ActionLifecycleEvent)
		table.insert(order, "Started " .. event.actionId)
	end)
	actions.OnActionInterrupted:Connect(function(event: ActionTypes.ActionInterruptedEvent)
		table.insert(order, "Interrupted " .. event.actionId)
		if event.actionId == "Owner" then
			nested = actions:RequestAction("Replacement")
			table.insert(order, "nested returned")
		end
	end)
	expect(actions:RequestAction("Incoming")).toEqual({ accepted = true, sequenceId = 2 })
	expect(nested).toEqual({ accepted = true, sequenceId = 3 })
	expect(order).toEqual({
		"Interrupted Owner",
		"Started Incoming",
		"Interrupted Incoming",
		"Started Replacement",
		"nested returned",
	})
	expect(tags:HasTag("Active")).toBe(false)
end)

it("commits every preempted owner and incoming Tag before lifecycle and Tag callbacks", function()
	local contexts: { ActionTypes.ActionExecutionContext } = {}
	local order: { string } = {}
	local definitions: { ActionDefinition } = {}
	for _, name: string in { "Hands", "Movement" } do
		table.insert(definitions, {
			id = name,
			visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
			autoGrant = true,
			locks = { name },
			interruptibleBy = { "Incoming" },
			activeTags = { name },
			appliedTags = { "Applied" },
			onStart = function(context: ActionTypes.ActionExecutionContext)
				table.insert(contexts, context)
			end,
			onInterrupt = function()
				table.insert(order, "hook " .. name)
			end,
		})
	end
	table.insert(definitions, {
		id = "Incoming",
		visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
		autoGrant = true,
		locks = { "Movement", "Hands" },
		activeTags = { "Active", "Ready" },
		onStart = function()
			table.insert(order, "incoming hook")
		end,
	})
	table.insert(definitions, {
		id = "Probe",
		visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
		autoGrant = true,
		locks = { "Hands", "Movement" },
	})
	initialize(definitions, {
		tag("Hands", "Stack"),
		tag("Movement", "Stack"),
		tag("Applied", "Stack"),
		tag("Active", "Stack"),
		tag("Ready", "Stack"),
	})
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect(actions:RequestAction("Hands").accepted).toBe(true)
	expect(actions:RequestAction("Movement").accepted).toBe(true)
	local observations: { boolean } = {}
	local probes: { ActionTypes.ActionRequestResult } = {}
	local function observe(): ()
		table.insert(
			observations,
			not contexts[1]:IsActive()
				and not contexts[2]:IsActive()
				and not tags:HasTag("Hands")
				and not tags:HasTag("Movement")
				and tags:HasTag("Active")
				and tags:HasTag("Ready")
				and #tags:GetTagInstances("Applied") == 2
		)
	end
	actions.OnActionInterrupted:Connect(function(event: ActionTypes.ActionInterruptedEvent)
		observe()
		table.insert(order, "Interrupted " .. event.actionId)
	end)
	actions.OnActionStarted:Connect(function()
		observe()
		table.insert(order, "Started")
	end)
	tags.OnTagRemoved:Connect(function(_owner: Actor, tagId: string)
		observe()
		table.insert(probes, actions:RequestAction("Probe"))
		table.insert(order, "Removed " .. tagId)
	end)
	tags.OnTagAdded:Connect(function(_owner: Actor, tagId: string)
		observe()
		table.insert(order, "Added " .. tagId)
	end)
	expect(actions:RequestAction("Incoming")).toEqual({ accepted = true, sequenceId = 3 })
	expect(observations).toEqual({ true, true, true, true, true, true, true })
	expect(probes).toEqual({
		{ accepted = false, reason = "ActionLockConflict" },
		{ accepted = false, reason = "ActionLockConflict" },
	})
	expect(order).toEqual({
		"Interrupted Hands",
		"Interrupted Movement",
		"Started",
		"Removed Hands",
		"Removed Movement",
		"Added Active",
		"Added Ready",
		"hook Hands",
		"hook Movement",
		"incoming hook",
	})
end)

for _, terminal: string in { "End", "Interrupt" } do
	it("allows synchronous reentry from Tag cleanup after " .. terminal .. " commits all terminal state", function()
		local context: ActionTypes.ActionExecutionContext? = nil
		local order: { string } = {}
		initialize({
			{
				id = "Owner",
				visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
				autoGrant = true,
				locks = { "Hands" },
				activeTags = { "Active", "Ready" },
				appliedTags = { "Applied" },
				onStart = function(started: ActionTypes.ActionExecutionContext)
					context = started
				end,
				onEnd = function()
					table.insert(order, "terminal hook")
				end,
				onInterrupt = function()
					table.insert(order, "terminal hook")
				end,
			},
			{
				id = "Followup",
				visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
				autoGrant = true,
				locks = { "Hands" },
				blockedTags = { "Active", "Ready" },
				requiredTags = { "Applied" },
				onStart = function()
					table.insert(order, "followup hook")
				end,
			},
		}, { tag("Active", "Stack"), tag("Ready", "Stack"), tag("Applied", "Stack") })
		local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
		expect(actions:RequestAction("Owner")).toEqual({ accepted = true, sequenceId = 1 })
		local clean: { boolean } = {}
		local nested: ActionTypes.ActionRequestResult? = nil
		local repeatedEnd: boolean? = nil
		local repeatedReason: string? = nil
		local function observeTerminal(): ()
			table.insert(order, "terminal signal")
			table.insert(clean, not tags:HasTag("Active") and not tags:HasTag("Ready") and tags:HasTag("Applied"))
		end
		actions.OnActionEnded:Connect(observeTerminal)
		actions.OnActionInterrupted:Connect(observeTerminal)
		tags.OnTagRemoved:Connect(function(_owner: Actor, tagId: string)
			table.insert(
				clean,
				not (context :: ActionTypes.ActionExecutionContext):IsActive()
					and not tags:HasTag("Active")
					and not tags:HasTag("Ready")
			)
			if tagId == "Active" then
				repeatedEnd, repeatedReason = actions:EndAction(1)
				nested = actions:RequestAction("Followup")
				table.insert(order, "nested returned")
			end
		end)
		local stopped: boolean, reason: string?
		if terminal == "End" then
			stopped, reason = actions:EndAction(1)
		else
			stopped, reason = actions:InterruptAction(1, "Test")
		end
		expect(stopped).toBe(true)
		expect(reason).toBeNil()
		expect(clean).toEqual({ true, true, true })
		expect(repeatedEnd).toBe(false)
		expect(repeatedReason).toBe("ActionInstanceNotActive")
		expect(nested).toEqual({ accepted = true, sequenceId = 2 })
		expect(order).toEqual({ "terminal signal", "followup hook", "nested returned", "terminal hook" })
	end)
end

it("resolves committed Property modifiers in lifecycle listeners before Tag notifications", function()
	initialize({
		{
			id = "Owner",
			visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
			autoGrant = true,
			activeTags = { "Haste" },
		},
	}, {
		{
			id = "Haste",
			visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
			duplicateBehavior = "Stack",
			properties = { WalkSpeed = { add = 5 } },
		},
	})
	local actor: Actor, actions: ActionController, _tags: TagController = registerActor()
	local properties: PropertyTypes.PropertyController =
		actor:GetController("PropertyController") :: PropertyTypes.PropertyController
	local values: { number? } = {}
	local changes: { { number? } } = {}
	local function observe(): ()
		table.insert(values, properties:GetResolvedProperty("WalkSpeed"))
		table.insert(values, properties:GetResolvedProperties().WalkSpeed)
	end
	actions.OnActionStarted:Connect(observe)
	actions.OnActionEnded:Connect(observe)
	properties.OnResolvedPropertyChanged:Connect(
		function(_owner: Actor, propertyName: string, previous: number?, current: number)
			if propertyName == "WalkSpeed" then
				table.insert(changes, { previous, current })
			end
		end
	)
	expect(actions:RequestAction("Owner")).toEqual({ accepted = true, sequenceId = 1 })
	expect((actions:EndAction(1))).toBe(true)
	expect(values).toEqual({ 21, 21, 16, 16 })
	expect(changes).toEqual({ { 16, 21 }, { 21, 16 } })
end)

it("finishes accepted lifecycle dispatch when an activation Tag listener unregisters the Actor", function()
	local order: { string } = {}
	initialize({
		{
			id = "Owner",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Active", "Ready" },
			onStart = function()
				table.insert(order, "start hook")
			end,
			onInterrupt = function()
				table.insert(order, "interrupt hook")
			end,
		},
	}, { tag("Active", "Stack"), tag("Ready", "Stack") })
	local actor: Actor, actions: ActionController, tags: TagController = registerActor()
	actions.OnActionStarted:Connect(function()
		table.insert(order, "Started")
	end)
	actions.OnActionInterrupted:Connect(function()
		table.insert(order, "Interrupted")
	end)
	tags.OnTagAdded:Connect(function()
		table.insert(order, "TagAdded")
		ActorRuntime.UnregisterActor(actor, "Test")
	end)
	expect(actions:RequestAction("Owner")).toEqual({ accepted = true, sequenceId = 1 })
	expect(order).toEqual({ "Started", "TagAdded", "Interrupted", "interrupt hook" })
	expect(ActorRegistry.GetActorById(actor:GetId())).toBeNil()
end)

it("commits scoped preemption cleanup before signals, Tag reentry, and owner hooks", function()
	local claimant: ActionTypes.ActionExecutionContext? = nil
	local order: { string } = {}
	initialize({
		{
			id = "Owner",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Claimant" },
			activeTags = { "Active", "Ready" },
			onInterrupt = function()
				table.insert(order, "interrupt hook")
			end,
		},
		{
			id = "Claimant",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(context: ActionTypes.ActionExecutionContext)
				claimant = context
			end,
		},
		{ id = "Probe", visibility = "ServerOnly", autoGrant = true, locks = { "Hands" } },
	}, { tag("Active", "Stack"), tag("Ready", "Stack") })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect(actions:RequestAction("Owner").accepted).toBe(true)
	expect(actions:RequestAction("Claimant").accepted).toBe(true)
	local clean: { boolean } = {}
	local probes: { ActionTypes.ActionRequestResult } = {}
	actions.OnActionInterrupted:Connect(function()
		table.insert(clean, not tags:HasTag("Active") and not tags:HasTag("Ready"))
		table.insert(order, "Interrupted")
	end)
	tags.OnTagRemoved:Connect(function()
		table.insert(clean, not tags:HasTag("Active") and not tags:HasTag("Ready"))
		table.insert(probes, actions:RequestAction("Probe"))
		table.insert(order, "TagRemoved")
	end)
	local claim: ActionTypes.LockClaim?, reason: string? = (claimant :: ActionTypes.ActionExecutionContext):ClaimLocks({
		"Hands",
	})
	expect(claim).never.toBeNil()
	expect(reason).toBeNil()
	expect(clean).toEqual({ true, true, true })
	expect(order).toEqual({ "Interrupted", "TagRemoved", "TagRemoved", "interrupt hook" })
	expect(probes).toEqual({
		{ accepted = false, reason = "ActionLockConflict" },
		{ accepted = false, reason = "ActionLockConflict" },
	})
	local acquiredClaim: ActionTypes.LockClaim = claim :: ActionTypes.LockClaim
	acquiredClaim:Release()
	expect(actions:RequestAction("Probe")).toEqual({ accepted = true, sequenceId = 3 })
end)

it("preserves refreshed capped stacks while cleaning only the exact remaining owned records", function()
	initialize({
		{
			id = "Owner",
			visibility = "ServerOnly",
			autoGrant = true,
			activeTags = { "Stack", { id = "Stack", duration = 4 }, { id = "Stack", duration = 8 } },
		},
	}, { { id = "Stack", visibility = "ServerOnly", duplicateBehavior = "Stack", maxStacks = 2, defaultDuration = 2 } })
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect(actions:RequestAction("Owner")).toEqual({ accepted = true, sequenceId = 1 })
	expect(#tags:GetTagInstances("Stack")).toBe(2)
	expect((tags:AddTag("Stack", { duration = 12 }))).toBe(true)
	expect((actions:EndAction(1))).toBe(true)
	local remaining: { TagTypes.TagInstanceSnapshot } = tags:GetTagInstances("Stack")
	expect(#remaining).toBe(1)
	expect(remaining[1].duration).toBe(12)
end)

it("rejects unavailable Tag controllers before consuming an id or preempting an owner", function()
	initialize({
		{
			id = "Owner",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			interruptibleBy = { "Incoming" },
		},
		{
			id = "Incoming",
			visibility = "ServerOnly",
			autoGrant = true,
			locks = { "Hands" },
			activeTags = { "Active" },
		},
		{ id = "Idle", visibility = "ServerOnly", autoGrant = true },
	}, { tag("Active", "Stack") })
	local actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect(actions:RequestAction("Owner")).toEqual({ accepted = true, sequenceId = 1 })
	actor:RemoveController("TagController")
	expect(actions:RequestAction("Incoming")).toEqual({ accepted = false, reason = "ActionTagActivationFailed:Active" })
	expect(actor:SetController("TagController", tags)).toBe(true)
	tags:Destroy()
	expect(actions:RequestAction("Incoming")).toEqual({ accepted = false, reason = "ActionTagActivationFailed:Active" })
	expect((actions:EndAction(1))).toBe(true)
	expect(actions:RequestAction("Idle")).toEqual({ accepted = true, sequenceId = 2 })
end)

it("leaves all conflict owners and Tags intact when a later incoming application fails validation", function()
	local definitions: { ActionDefinition } = {}
	local contexts: { ActionTypes.ActionExecutionContext } = {}
	for _, name: string in { "Hands", "Movement" } do
		table.insert(definitions, {
			id = name,
			visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
			autoGrant = true,
			locks = { name },
			interruptibleBy = { "Incoming" },
			activeTags = { name },
			onStart = function(context: ActionTypes.ActionExecutionContext)
				table.insert(contexts, context)
			end,
		})
	end
	table.insert(definitions, {
		id = "Incoming",
		visibility = "ServerOnly" :: ActionTypes.ActionVisibility,
		autoGrant = true,
		locks = { "Hands", "Movement" },
		activeTags = { "Active" },
		appliedTags = { "Applied" },
		onCanStart = function(): (boolean, string?)
			TagRegistry._resetForTests()
			TagRegistry.Load({ tag("Hands", "Stack"), tag("Movement", "Stack"), tag("Active", "Stack") })
			return true, nil
		end,
	})
	table.insert(
		definitions,
		{ id = "Idle", visibility = "ServerOnly" :: ActionTypes.ActionVisibility, autoGrant = true }
	)
	initialize(
		definitions,
		{ tag("Hands", "Stack"), tag("Movement", "Stack"), tag("Active", "Stack"), tag("Applied", "Stack") }
	)
	local _actor: Actor, actions: ActionController, tags: TagController = registerActor()
	expect(actions:RequestAction("Hands").accepted).toBe(true)
	expect(actions:RequestAction("Movement").accepted).toBe(true)
	local events: number = 0
	actions.OnActionInterrupted:Connect(function()
		events += 1
	end)
	tags.OnTagChanged:Connect(function()
		events += 1
	end)
	expect(actions:RequestAction("Incoming")).toEqual({ accepted = false, reason = "ActionTagActivationFailed:Applied" })
	expect(contexts[1]:IsActive()).toBe(true)
	expect(contexts[2]:IsActive()).toBe(true)
	expect(tags:HasTag("Hands")).toBe(true)
	expect(tags:HasTag("Movement")).toBe(true)
	expect(tags:HasTag("Active")).toBe(false)
	expect(tags:HasTag("Applied")).toBe(false)
	expect(events).toBe(0)
	expect(actions:RequestAction("Idle")).toEqual({ accepted = true, sequenceId = 3 })
end)
