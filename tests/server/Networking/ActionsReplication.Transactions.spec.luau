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
local NetworkingTypes = require(KRF.server.Networking.types)
local GoodSignal: any = require(KRF.shared.Signal.GoodSignal)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActionsReplicationTestUtils)

local originalFire: any = GoodSignal.Fire
beforeEach(ActionUtils.reset)

afterEach(function()
	GoodSignal.Fire = originalFire
	ActionUtils.cleanup()
end)

local function event(kind: string, id: string, sequence: number): NetworkingTypes.PublicationEvent
	return { domainId = "KRF.Actions", eventId = kind, payload = { actionId = id, sequenceId = sequence } }
end

it("seals Resource cost, owned Tags and Started as one commit before lifecycle Fire or yieldable onStart", function()
	local depth: number = 0
	local groups: number = 0
	local commits: { NetworkingTypes.PublicationCommit } = {}
	local hooks: { any } = {}

	local definition: ActionTypes.ActionDefinition = TestUtils.action("Incoming")
	definition.costs = { Mana = 20 }
	definition.activeTags = { "Incoming" }

	definition.onStart = function()
		table.insert(hooks, { depth = depth, commits = #commits })
		coroutine.yield()
	end

	TestUtils.initialize({ definition })
	local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
	local publication: NetworkingTypes.PublicationRuntime = TestUtils.publication()
	commits = TestUtils.observe()
	local withActorCommit = publication.WithActorCommit

	publication.WithActorCommit = function(
		self: NetworkingTypes.PublicationRuntime,
		target: ActorTypes.Actor,
		callback: () -> ()
	)
		groups += 1
		depth += 1
		withActorCommit(self, target, callback)
		depth -= 1
	end

	local atFire: { any } = {}

	GoodSignal.Fire = function(self: any, ...: any)
		local payload: any = ...

		if type(payload) == "table" and payload.actor == actor and payload.actionId == "Incoming" then
			table.insert(atFire, { depth = depth, commits = #commits, baseline = publication:CaptureBaseline(actor) })
		end

		originalFire(self, ...)
	end

	TestUtils.accept(actions, "Incoming", { private = "NeverSerialize", callback = function() end })
	expect(groups).toBe(1)
	expect(hooks).toEqual({ { depth = 0, commits = 1 } })
	expect(#commits).toBe(1)
	expect(TestUtils.events(commits[1])).toEqual({ event("Started", "Incoming", 1) })
	expect(#commits[1].patches).toBe(3)
	expect(#atFire).toBe(1)
	expect(atFire[1].depth).toBe(0)
	expect(atFire[1].commits).toBe(1)
	expect(atFire[1].baseline.domains["KRF.Resources"].value.Mana.anchorValue).toBe(80)
	expect(atFire[1].baseline.domains["KRF.Tags"].value.Incoming).toEqual({ stackCount = 1 })
	expect(atFire[1].baseline.domains["KRF.Actions"].value).toEqual({ [1] = "Incoming" })
end)

for _, privateOwner: boolean in { false, true } do
	it(
		"preempts owners in sequence order before incoming Started with coherent final Tags, private owner="
			.. tostring(privateOwner),
		function()
			local first: ActionTypes.ActionDefinition = TestUtils.action("A")
			first.locks = { "Hands" }
			first.activeTags = { "OwnerA" }
			first.interruptibleBy = { "Incoming" }

			local second: ActionTypes.ActionDefinition =
				TestUtils.action("B", if privateOwner then "ServerOnly" else "ClientVisible")

			second.locks = { "Feet" }
			second.activeTags = { "OwnerB" }
			second.interruptibleBy = { "Incoming" }

			local incoming: ActionTypes.ActionDefinition = TestUtils.action("Incoming")
			incoming.locks = { "Feet", "Hands" }
			incoming.activeTags = { "Incoming" }
			incoming.costs = { Mana = 20 }
			TestUtils.initialize({ first, second, incoming })
			local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
			TestUtils.accept(actions, "A")
			TestUtils.accept(actions, "B")
			local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
			TestUtils.accept(actions, "Incoming")
			expect(#commits).toBe(1)
			local expected: { NetworkingTypes.PublicationEvent } = { event("Interrupted", "A", 1) }

			if not privateOwner then
				table.insert(expected, event("Interrupted", "B", 2))
			end

			table.insert(expected, event("Started", "Incoming", 3))
			expect(TestUtils.events(commits[1])).toEqual(expected)
			expect(TestUtils.state(actor)).toEqual({ [3] = "Incoming" })
			local baseline: NetworkingTypes.PublicationBaseline? = TestUtils.publication():CaptureBaseline(actor)
			assert(baseline ~= nil, "Expected final grouped baseline")
			expect(baseline.domains["KRF.Tags"].value).toEqual({ Incoming = { stackCount = 1 } })
			expect(baseline.domains["KRF.Resources"].value.Mana.anchorValue).toBe(80)
		end
	)
end

for _, terminal: string in { "Ended", "Interrupted" } do
	it("groups direct " .. terminal .. " with owned Tag cleanup before the authored terminal hook", function()
		local seen: { any } = {}
		local publication: NetworkingTypes.PublicationRuntime? = nil
		local commits: { NetworkingTypes.PublicationCommit } = {}

		local definition: ActionTypes.ActionDefinition = TestUtils.action("Visible")
		definition.activeTags = { "OwnerA" }

		local function capture(context: ActionTypes.ActionExecutionContext, reason: string?)
			assert(publication ~= nil, "Expected publication installation")

			table.insert(
				seen,
				{ count = #commits, baseline = publication:CaptureBaseline(context.actor), reason = reason }
			)
		end

		definition.onEnd = function(context: ActionTypes.ActionExecutionContext)
			capture(context, nil)
		end

		definition.onInterrupt = capture
		TestUtils.initialize({ definition })
		local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
		publication = TestUtils.publication()
		TestUtils.accept(actions, "Visible")
		commits = TestUtils.observe()

		if terminal == "Ended" then
			expect(actions:EndAction(1)).toBe(true)
		else
			expect(actions:InterruptAction(1, "Private.Reason")).toBe(true)
		end

		expect(#commits).toBe(1)
		expect(TestUtils.events(commits[1])).toEqual({ event(terminal, "Visible", 1) })
		expect(#seen).toBe(1)
		expect(seen[1].count).toBe(1)
		expect(seen[1].reason).toBe(if terminal == "Ended" then nil else "Private.Reason")
		expect(seen[1].baseline.domains["KRF.Actions"].value).toEqual({})
		expect(seen[1].baseline.domains["KRF.Tags"].value).toEqual({})
		expect(TestUtils.state(actor)).toEqual({})
	end)
end

it("groups scoped ClaimLocks preemption and leaves the claimant identity active without a synthetic Started", function()
	local owner: ActionTypes.ActionDefinition = TestUtils.action("Owner")
	owner.locks = { "Hands" }
	owner.activeTags = { "OwnerA" }
	owner.interruptibleBy = { "Claimant" }

	local context: ActionTypes.ActionExecutionContext? = nil

	local claimant: ActionTypes.ActionDefinition = TestUtils.action("Claimant")

	claimant.onStart = function(current: ActionTypes.ActionExecutionContext)
		context = current
	end

	TestUtils.initialize({ owner, claimant })
	local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
	TestUtils.accept(actions, "Owner")
	TestUtils.accept(actions, "Claimant")
	local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
	assert(context ~= nil, "Expected real claimant execution context")
	local claim: ActionTypes.LockClaim?, reason: string? = context:ClaimLocks({ "Hands" })
	expect(reason).toBeNil()
	expect(claim).never.toBeNil()
	expect(#commits).toBe(1)
	expect(TestUtils.events(commits[1])).toEqual({ event("Interrupted", "Owner", 1) })
	expect(TestUtils.state(actor)).toEqual({ [2] = "Claimant" })
	assert(claim ~= nil, "Expected accepted claim")
	claim:Release()
	expect(#commits).toBe(1)
end)

it("groups controller destruction into ordered visible terminal truth before public callbacks", function()
	local first: ActionTypes.ActionDefinition = TestUtils.action("A")
	first.activeTags = { "OwnerA" }

	local second: ActionTypes.ActionDefinition = TestUtils.action("B")
	second.activeTags = { "OwnerB" }
	TestUtils.initialize({ first, TestUtils.action("Private", "ServerOnly"), second })
	local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
	TestUtils.accept(actions, "A")
	TestUtils.accept(actions, "Private")
	TestUtils.accept(actions, "B")
	local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
	local atCallback: { number } = {}

	actions.OnActionInterrupted:Connect(function()
		table.insert(atCallback, #commits)
	end)

	actions:Destroy()
	expect(#commits).toBe(1)
	expect(TestUtils.events(commits[1])).toEqual({ event("Interrupted", "A", 1), event("Interrupted", "B", 3) })
	expect(atCallback).toEqual({ 1, 1, 1 })
	expect(TestUtils.state(actor)).toEqual({})
	actions:Destroy()
	expect(#commits).toBe(1)
end)

for _, terminal: string in { "Ended", "Interrupted", "StartFailed" } do
	it("keeps Started and immediate " .. terminal .. " in separate logical commits after onStart reentry", function()
		local definition: ActionTypes.ActionDefinition = TestUtils.action("Visible")

		definition.onStart = function(context: ActionTypes.ActionExecutionContext)
			if terminal == "Ended" then
				context:End()
			elseif terminal == "Interrupted" then
				context:Interrupt("Private.Reason")
			else
				error("ExpectedAuthoredStartFailure", 0)
			end
		end

		TestUtils.initialize({ definition })
		local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
		local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
		TestUtils.accept(actions, "Visible")
		expect(#commits).toBe(2)
		expect(commits[1].sequence).toBe(1)
		expect(commits[2].sequence).toBe(2)
		expect(TestUtils.events(commits[1])).toEqual({ event("Started", "Visible", 1) })

		expect(TestUtils.events(commits[2])).toEqual({
			event(if terminal == "Ended" then "Ended" else "Interrupted", "Visible", 1),
		})

		expect(TestUtils.state(actor)).toEqual({})
	end)
end

it(
	"publishes a visible owner's interruption when preempted by a private Action without leaking the incoming identity",
	function()
		local owner: ActionTypes.ActionDefinition = TestUtils.action("Visible")
		owner.locks = { "Hands" }
		owner.interruptibleBy = { "Private" }

		local private: ActionTypes.ActionDefinition = TestUtils.action("Private", "ServerOnly")
		private.locks = { "Hands" }
		TestUtils.initialize({ owner, private })
		local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
		TestUtils.accept(actions, "Visible")
		local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
		TestUtils.accept(actions, "Private", { secret = "Private.Parameters" })
		expect(#commits).toBe(1)
		expect(TestUtils.events(commits[1])).toEqual({ event("Interrupted", "Visible", 1) })
		expect(TestUtils.state(actor)).toEqual({})
		expect(actions:EndAction(2)).toBe(true)
		expect(#commits).toBe(1)
	end
)
