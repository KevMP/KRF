--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Actor.types)
local ClientTypes = require(KRF.client.Networking.types)
local GoodSignal: any = require(KRF.shared.Signal.GoodSignal)
local ActorUtils = require(script.Parent.Utils.ActorViewTestUtils)
local StreamUtils = require(script.Parent.Utils.ActorStreamTestUtils)
local TestUtils = require(script.Parent.Utils.ActionsViewTestUtils)

local fixture: ActorUtils.Fixture
local originalFire: any = GoodSignal.Fire
local originalConnect: any = GoodSignal.Connect
local signalEnvironment: any = getfenv(originalFire)
local suspended: { thread } = {}

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	GoodSignal.Fire = originalFire
	GoodSignal.Connect = originalConnect
	setfenv(originalFire, signalEnvironment)

	for _, handler: thread in suspended do
		pcall(task.cancel, handler)
	end

	suspended = {}
	ActorUtils.destroy(fixture)
end)

for _, terminal: string in { "Ended", "Interrupted" } do
	it("installs each logical state before Started and " .. terminal .. " Fire within one physical packet", function()
		local actions: TestUtils.ActionsView = TestUtils.get(TestUtils.baseline(fixture, {}))
		local signals: { [any]: string } = {}
		local connecting: string = ""

		GoodSignal.Connect = function(self: any, callback: any): any
			signals[self] = connecting

			return originalConnect(self, callback)
		end

		for _, kind: string in { "Started", "Ended", "Interrupted" } do
			connecting = kind
			local lifecycleEvent: any = (actions :: any)["OnAction" .. kind]
			lifecycleEvent:Connect(function() end)
		end

		GoodSignal.Connect = originalConnect

		local fires: { any } = {}

		GoodSignal.Fire = function(self: any, ...: any)
			if signals[self] ~= nil then
				local snapshot: TestUtils.Snapshot = ...

				table.insert(fires, {
					kind = signals[self],
					snapshot = snapshot,
					current = actions:GetAction(snapshot.sequenceId),
					frozen = table.isfrozen(snapshot),
				})
			end

			originalFire(self, ...)
		end

		ActorUtils.send(fixture, {
			{
				kind = "Commit",
				handle = 1,
				revision = 11,
				patches = { TestUtils.patch({ [1] = "Action.A" }, {}) },
				events = { TestUtils.event("Started", "Action.A", 1) },
			},
			{
				kind = "Commit",
				handle = 1,
				revision = 12,
				patches = { TestUtils.patch({}, { 1 }) },
				events = { TestUtils.event(terminal, "Action.A", 1) },
			},
		})

		expect(fires).toEqual({
			{
				kind = "Started",
				snapshot = { actionId = "Action.A", sequenceId = 1 },
				current = { actionId = "Action.A", sequenceId = 1 },
				frozen = true,
			},
			{ kind = terminal, snapshot = { actionId = "Action.A", sequenceId = 1 }, frozen = true },
		})

		expect(actions:GetActiveActions()).toEqual({})
	end)
end

it("does not infer lifecycle events from initial or replacement state and preserves original subscriptions", function()
	local initialFires: { any } = {}

	GoodSignal.Fire = function(self: any, ...: any)
		local first: any = ...

		if type(first) == "table" and first.actionId ~= nil then
			table.insert(initialFires, first)
		end

		originalFire(self, ...)
	end

	local actor: Types.ActorView = TestUtils.baseline(fixture, { [5] = "Action.A" })
	local actions: TestUtils.ActionsView = TestUtils.get(actor)
	expect(initialFires).toEqual({})
	local events: { any } = {}
	local changes: { Types.DomainChangeSource } = {}

	actions.OnActionStarted:Connect(function(snapshot: TestUtils.Snapshot)
		table.insert(events, { "Started", snapshot })
	end)

	actions.OnActionEnded:Connect(function(snapshot: TestUtils.Snapshot)
		table.insert(events, { "Ended", snapshot })
	end)

	actions.OnActionInterrupted:Connect(function(snapshot: TestUtils.Snapshot)
		table.insert(events, { "Interrupted", snapshot })
	end)

	actions.OnStateChanged:Connect(function(source: Types.DomainChangeSource)
		table.insert(changes, source)
	end)

	ActorUtils.commit(fixture, 12)
	expect(#fixture.requests).toBe(1)
	ActorUtils.baseline(fixture, 1, nil, 50, TestUtils.truth({ [9] = "Action.B" }), 2)
	expect(ActorUtils.view(fixture)).toBe(actor)
	expect(TestUtils.get(actor)).toBe(actions)
	expect(actions:GetActiveActions()).toEqual({ { actionId = "Action.B", sequenceId = 9 } })
	expect(events).toEqual({})
	expect(changes).toEqual({ "Baseline" })
	ActorUtils.baseline(fixture, 1, nil, 60, TestUtils.truth({ [9] = "Action.B" }), 3)
	expect(changes).toEqual({ "Baseline" })
	ActorUtils.commit(fixture, 61, { TestUtils.patch({}, { 9 }) }, { TestUtils.event("Ended", "Action.B", 9) })
	expect(changes).toEqual({ "Baseline", "Commit" })
	expect(events).toEqual({ { "Ended", { actionId = "Action.B", sequenceId = 9 } } })
end)

it("keeps historical Started identity while a yielding listener later observes terminal current truth", function()
	local actions: TestUtils.ActionsView = TestUtils.get(TestUtils.baseline(fixture, {}))
	local resumed: { any } = {}

	actions.OnActionStarted:Connect(function(snapshot: TestUtils.Snapshot)
		table.insert(suspended, coroutine.running())
		coroutine.yield()
		table.insert(resumed, { snapshot = snapshot, current = actions:GetAction(snapshot.sequenceId) })
	end)

	ActorUtils.commit(
		fixture,
		11,
		{ TestUtils.patch({ [1] = "Action.A" }, {}) },
		{ TestUtils.event("Started", "Action.A", 1) }
	)

	expect(#suspended).toBe(1)
	ActorUtils.commit(fixture, 12, { TestUtils.patch({}, { 1 }) }, { TestUtils.event("Ended", "Action.A", 1) })
	expect(actions:GetAction(1)).toBeNil()
	expect(resumed).toEqual({})
	local completed: boolean, reason: any = coroutine.resume(suspended[1])
	table.remove(suspended, 1)
	expect(completed).toBe(true)
	expect(reason).toBeNil()
	expect(resumed).toEqual({ { snapshot = { actionId = "Action.A", sequenceId = 1 } } })
	expect(fixture.requests).toEqual({})
end)

it("continues state installation and lifecycle delivery when a consumer throws", function()
	local errors: { string } = {}

	local scheduler: any = table.clone(task)

	scheduler.spawn = function(runner: thread, ...: any): thread
		local completed: boolean, reason: any = coroutine.resume(runner, ...)

		if not completed then
			table.insert(errors, tostring(reason))
		end

		return runner
	end

	setfenv(originalFire, setmetatable({ task = scheduler }, { __index = signalEnvironment }))
	local actions: TestUtils.ActionsView = TestUtils.get(TestUtils.baseline(fixture, {}))

	actions.OnActionStarted:Connect(function()
		error("N8ExpectedConsumerFailure", 0)
	end)

	local ended: { TestUtils.Snapshot } = {}

	actions.OnActionEnded:Connect(function(snapshot: TestUtils.Snapshot)
		table.insert(ended, snapshot)
	end)

	ActorUtils.commit(
		fixture,
		11,
		{ TestUtils.patch({ [1] = "Action.A" }, {}) },
		{ TestUtils.event("Started", "Action.A", 1) }
	)

	ActorUtils.commit(fixture, 12, { TestUtils.patch({}, { 1 }) }, { TestUtils.event("Ended", "Action.A", 1) })
	expect(errors).toEqual({ "N8ExpectedConsumerFailure" })
	expect(ended).toEqual({ { actionId = "Action.A", sequenceId = 1 } })
	expect(actions:GetActiveActions()).toEqual({})
	expect(fixture.requests).toEqual({})
	expect(fixture.faults).toEqual({})
end)

it("preserves state and subscriptions through Model stream-out and rebind", function()
	local actor: Types.ActorView = TestUtils.baseline(fixture, { [1] = "Action.A" })
	local actions: TestUtils.ActionsView = TestUtils.get(actor)
	local changes: number = 0

	actions.OnStateChanged:Connect(function()
		changes += 1
	end)

	local candidate: ClientTypes.ActorModelCandidate = StreamUtils.candidate(fixture.stream, "ActorA")
	StreamUtils.add(fixture.stream, candidate)
	StreamUtils.remove(fixture.stream, candidate)
	expect(actor:GetModel()).toBeNil()
	expect(TestUtils.get(actor)).toBe(actions)
	expect(actions:GetAction(1)).toEqual({ actionId = "Action.A", sequenceId = 1 })
	expect(changes).toBe(0)
	StreamUtils.add(fixture.stream, candidate)
	ActorUtils.commit(fixture, 11, { TestUtils.patch({}, { 1 }) }, { TestUtils.event("Ended", "Action.A", 1) })
	expect(actor:GetModel()).toBe(candidate.model)
	expect(changes).toBe(1)
end)

it("retires every Action Event and never binds a stale view to a respawn", function()
	local actions: TestUtils.ActionsView = TestUtils.get(TestUtils.baseline(fixture, { [1] = "Action.A" }))
	local callbacks: number = 0

	actions.OnActionStarted:Connect(function()
		callbacks += 1
	end)

	ActorUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })
	expect(actions:GetActiveActions()).toEqual({})

	for _, name: string in { "OnActionStarted", "OnActionEnded", "OnActionInterrupted", "OnStateChanged" } do
		expect(pcall(function()
			(actions :: any)[name]:Connect(function() end)
		end)).toBe(false)
	end

	ActorUtils.baseline(fixture, 2, "Respawn", 0, TestUtils.truth({}))
	local respawn: TestUtils.ActionsView = TestUtils.get(ActorUtils.view(fixture, "Respawn"))
	expect(respawn).never.toBe(actions)

	ActorUtils.commit(
		fixture,
		1,
		{ TestUtils.patch({ [2] = "Action.B" }, {}) },
		{ TestUtils.event("Started", "Action.B", 2) },
		2
	)

	expect(respawn:IsActionActive("Action.B")).toBe(true)
	expect(actions:GetActiveActions()).toEqual({})
	expect(callbacks).toBe(0)
end)

it("rejects a private id in a decoded commit without partially changing valid sibling Action entries", function()
	local actions: TestUtils.ActionsView = TestUtils.get(TestUtils.baseline(fixture, { [1] = "Action.A" }))
	local before: any = ActorUtils.domain(fixture, "KRF.Actions"):GetState()
	local callbacks: number = 0

	actions.OnActionStarted:Connect(function()
		callbacks += 1
	end)

	fixture.runtime.consumer.OnCommitReady(
		ActorUtils.actor(fixture),
		11,
		{ TestUtils.patch({ [2] = "Action.B", [3] = "Private.Secret" }, { 1 }) },
		{ TestUtils.event("Started", "Action.B", 2) }
	)

	expect(ActorUtils.domain(fixture, "KRF.Actions"):GetState()).toBe(before)
	expect(actions:GetActiveActions()).toEqual({ { actionId = "Action.A", sequenceId = 1 } })
	expect(actions:IsActionActive("Private.Secret")).toBe(false)
	expect(callbacks).toBe(0)
	expect(#fixture.requests).toBe(1)
	expect(#fixture.faults).toBe(1)
end)
