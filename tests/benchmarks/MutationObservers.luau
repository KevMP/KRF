--!strict
-- Uninstrumented server CPU; no transport/recipient latency is measured here.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local ActionTypes = require(KRF.server.Action.types)
local ResourceTypes = require(KRF.server.Resource.types)
local TagTypes = require(KRF.server.Tags.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local Server = require(KRF.server)
local ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local TagController = require(KRF.server.Tags.TagController)
local ResourceController = require(KRF.server.Resource.ResourceController)
local ActionUpdates = require(KRF.server.Action.utils.ActionControllerUpdates)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)

type Subject = {
	actor: ActorTypes.Actor,
	model: Model,
	actions: ActionTypes.InternalActionController,
	resources: ResourceTypes.InternalResourceController,
	tags: TagTypes.InternalTagController,
}

local rows: { any } = {}
local subjects: { Subject } = {}
local samples: number = 120
local warmup: number = 10

local function summarize(values: { number }): any
	table.sort(values)
	local total: number = 0

	for _, value: number in values do
		total += value
	end

	return {
		medianUs = values[math.ceil(#values / 2)],
		p95Us = values[math.ceil(#values * 0.95)],
		meanUs = total / #values,
	}
end

local function clean(): ()
	for _, subject: Subject in subjects do
		ActorRuntime.UnregisterActor(subject.actor, "BenchmarkComplete")
		subject.model:Destroy()
	end

	table.clear(subjects)
	Server._ResetForTests()
end

local function measure(name: string, operations: number, callback: () -> (), metadata: any): ()
	for _ = 1, warmup do
		callback()
	end

	local values: { number } = {}
	local heapBefore: number = gcinfo()

	for _ = 1, samples do
		local started: number = os.clock()
		callback()
		table.insert(values, (os.clock() - started) * 1000000 / operations)
		task.wait() -- Automatic controller stepping is disabled; never time this yield.
	end

	metadata.name = name
	metadata.operationsPerSample = operations
	metadata.latency = summarize(values)
	metadata.heapDeltaKB = gcinfo() - heapBefore -- Heap activity, not a retained-memory estimate.
	table.insert(rows, metadata)
end

local function workload(population: number, extraObservers: number, activePerActor: number): ()
	clean()
	TagController._setAutomaticSteppingEnabledForTests(false)
	ResourceController._setAutomaticSteppingEnabledForTests(false)
	ActionUpdates._setAutomaticSteppingEnabledForTests(false)
	local resources: { ResourceTypes.ResourceDefinition } = {}

	for index: number = 1, 6 do
		local definition: ResourceTypes.ResourceDefinition = {
			id = "Meter" .. index,
			visibility = "ClientVisible",
			autoAssign = true,
			initialValue = 1000000,
			max = { value = 1000000000 },
			regen = { rate = { value = 1 } },
		}

		table.insert(resources, definition)
	end

	local success: boolean, reason: any = Server.Init({
		resources = resources,
		tags = {
			{
				id = "Slow",
				visibility = "ClientVisible",
				duplicateBehavior = "Ignore",
				properties = { WalkSpeed = { set = 8 } },
			},
		},
		actions = {
			function(): ActionTypes.ActionDefinition
				return { id = "Idle", visibility = "ClientVisible", autoGrant = true }
			end,
			function(): ActionTypes.ActionDefinition
				return {
					id = "Cast",
					visibility = "ClientVisible",
					autoGrant = true,
					costs = { Meter1 = 1 },
					activeTags = { "Slow" },
				}
			end,
		},
	})

	assert(success, tostring(reason))
	local publication: NetworkingTypes.PublicationRuntime? = Networking._GetPublicationRuntimeForTests()
	assert(publication ~= nil, "Expected normal publication installation")
	local commits: number = 0
	local tagCallbacks: number = 0
	local resourceCallbacks: number = 0

	publication:ObserveCommits(function()
		commits += 1
	end)

	for _ = 1, population do
		local model: Model = Instance.new("Model")
		model.Parent = workspace
		local actor: ActorTypes.Actor?, failure: string? = ActorRuntime.RegisterActor(model)
		assert(actor ~= nil, failure)

		local subject: Subject = {
			actor = actor,
			model = model,
			actions = actor:GetController("ActionController") :: ActionTypes.InternalActionController,
			resources = actor:GetController("ResourceController") :: ResourceTypes.InternalResourceController,
			tags = actor:GetController("TagController") :: TagTypes.InternalTagController,
		}

		table.insert(subjects, subject)

		for _ = 1, activePerActor do
			assert(subject.actions:RequestAction("Idle").accepted, "Expected admitted concurrent setup Action")
		end

		for _ = 1, extraObservers do
			subject.tags:_observeMutations({
				Commit = function()
					tagCallbacks += 1
				end,
				Dispatch = function()
					tagCallbacks += 1
				end,
			})

			subject.resources:_observeMutations({
				includeRegenSteps = true,
				Commit = function()
					resourceCallbacks += 1
				end,
				Dispatch = function()
					resourceCallbacks += 1
				end,
			})
		end
	end

	local function metadata(): any
		return { actors = population, extraObservers = extraObservers, activePerActor = activePerActor }
	end

	local before: number = commits
	local callbacksBefore: number = resourceCallbacks

	measure("Regeneration6Meters", population * 6, function()
		for _, subject: Subject in subjects do
			subject.resources:Step(0.1)
		end
	end, metadata())

	assert(commits == before, "Ordinary regeneration must not publish anchors each step")

	assert(
		resourceCallbacks - callbacksBefore == population * 6 * (warmup + samples) * extraObservers * 2,
		"Regeneration observer delivery count differs"
	)

	before = commits
	callbacksBefore = tagCallbacks

	measure("TagAddRemoveWithProperties", population * 2, function()
		for _, subject: Subject in subjects do
			assert(subject.tags:AddTag("Slow"))
			assert(subject.tags:RemoveTag("Slow"))
		end
	end, metadata())

	assert(commits - before == population * 2 * (warmup + samples), "Tag publication lost a transition")

	assert(
		tagCallbacks - callbacksBefore == population * 2 * (warmup + samples) * extraObservers * 2,
		"Tag observer delivery count differs"
	)

	before = commits

	measure("ActionStartEndWithCostsTags", population * 2, function()
		for _, subject: Subject in subjects do
			local result: ActionTypes.ActionRequestResult = subject.actions:RequestAction("Cast")
			assert(result.accepted, "Expected admitted benchmark Action")
			assert(subject.actions:EndAction(result.sequenceId))
		end
	end, metadata())

	assert(commits - before == population * 2 * (warmup + samples), "Action publication lost a lifecycle transition")

	for _, subject: Subject in subjects do
		assert(#subject.actions:_getActiveReplicationState() == activePerActor, "Benchmark leaked an Action")
		assert(not subject.tags:HasTag("Slow"), "Benchmark leaked a Tag")
		local current: number? = subject.resources:GetCurrent("Meter1")

		assert(
			current ~= nil and math.abs(current - (1000000 - (warmup + samples) * 0.9)) < 0.0001,
			"Resource truth drifted"
		)
	end
end

local function callbackCosts(): ()
	local resumed: number = 0

	local function noop(): () end

	local function yielding(): ()
		task.wait(0.01)
		resumed += 1
	end

	for _, mode: string in { "PcallUnsafeReference", "CoroutineGuard", "YieldCancellation" } do
		measure(mode, 1000, function()
			for _ = 1, 1000 do
				if mode == "PcallUnsafeReference" then
					local called: boolean, callFailure: any = pcall(noop)
					assert(called, tostring(callFailure))
				else
					local thread: thread = coroutine.create(if mode == "YieldCancellation" then yielding else noop)
					local resumedSuccessfully: boolean, resumeFailure: any = coroutine.resume(thread)
					assert(resumedSuccessfully, tostring(resumeFailure))

					if coroutine.status(thread) ~= "dead" then
						pcall(task.cancel, thread)
						pcall(coroutine.close, thread)
					end
				end
			end
		end, {})
	end

	task.wait(0.03)
	assert(resumed == 0, "Canceled benchmark callbacks resumed")
end

local success: boolean, failure: any = pcall(function()
	callbackCosts()

	for _, population: number in { 30, 75, 90 } do
		for _, extraObservers: number in { 0, 1, 4 } do
			workload(population, extraObservers, if population == 90 then 32 else 2)
		end
	end
end)

clean()
TagController._setAutomaticSteppingEnabledForTests(true)
ResourceController._setAutomaticSteppingEnabledForTests(true)
ActionUpdates._setAutomaticSteppingEnabledForTests(true)
print("__KRF_NETWORKING_CPU_START__")

print(HttpService:JSONEncode({
	success = success,
	failure = tostring(failure),
	samples = samples,
	warmup = warmup,
	rows = rows,
}))

print("__KRF_NETWORKING_CPU_END__")

if not success then
	error(failure, 0)
end

return nil
