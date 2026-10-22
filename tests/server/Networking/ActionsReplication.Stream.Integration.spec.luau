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
local ReplicationTypes = require(KRF.server.Replication.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local ClientTypes = require(KRF.client.Actor.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Networking: NetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local Scheduler: NetworkingTypes.PublicationSchedulerModule = require(KRF.server.Networking.utils.PublicationScheduler)
local GoodSignal: any = require(KRF.shared.Signal.GoodSignal)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActionsReplicationTestUtils)
local ActorUtils = require(script.Parent.Parent.Parent.client.Utils.ActorViewTestUtils)
local ViewUtils = require(script.Parent.Parent.Parent.client.Utils.ActionsViewTestUtils)

local prepared: SharedTypes.PreparedProtocol? = nil
local client: ActorUtils.Fixture? = nil
local scheduler: NetworkingTypes.PublicationScheduler? = nil
local originalPrepare = Networking.Prepare
local originalFire: any = GoodSignal.Fire
local originalConnect: any = GoodSignal.Connect

beforeEach(function()
	ActionUtils.reset()
	prepared = nil

	Networking.Prepare = function(
		catalog: ReplicationTypes.PreparedReplicationDomainCatalog
	): (SharedTypes.PreparedProtocol?, string?)
		local protocol: SharedTypes.PreparedProtocol?, reason: string? = originalPrepare(catalog)
		prepared = protocol

		return protocol, reason
	end
end)

afterEach(function()
	GoodSignal.Fire = originalFire
	GoodSignal.Connect = originalConnect
	Networking.Prepare = originalPrepare

	if client ~= nil then
		ActorUtils.destroy(client)
		client = nil
	end

	if scheduler ~= nil then
		scheduler:Destroy()
		scheduler = nil
	end

	ActionUtils.cleanup()
end)

for _, terminal: string in { "Ended", "Interrupted" } do
	it(
		"carries real immediate Start -> " .. terminal .. " through N3 barriers and one encoded N4 packet into N5",
		function()
			local definition: ActionTypes.ActionDefinition = TestUtils.action("Visible")

			definition.onStart = function(context: ActionTypes.ActionExecutionContext)
				if terminal == "Ended" then
					context:End()
				else
					context:Interrupt("Private.Reason")
				end
			end

			TestUtils.initialize({ definition })
			local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
			TestUtils.domain()
			assert(prepared ~= nil, "Expected protocol from normal startup")
			local fixture: ActorUtils.Fixture = ActorUtils.new(nil, prepared.manifest)
			client = fixture
			local baseline: NetworkingTypes.PublicationBaseline? = TestUtils.publication():CaptureBaseline(actor)
			assert(baseline ~= nil, "Expected N3 baseline")
			ActorUtils.baseline(fixture, 1, actor:GetId(), baseline.sequence, baseline.domains)
			local view: ViewUtils.ActionsView = ViewUtils.get(ActorUtils.view(fixture, actor:GetId()))
			local history: { any } = {}

			view.OnActionStarted:Connect(function(snapshot: ViewUtils.Snapshot)
				table.insert(history, { "Started", snapshot })
			end)

			local terminalEvent: any = (view :: any)["OnAction" .. terminal]

			terminalEvent:Connect(function(snapshot: ViewUtils.Snapshot)
				table.insert(history, { terminal, snapshot })
			end)

			local queue: NetworkingTypes.PublicationScheduler = Scheduler.new({
				maxBarriers = 8,
				maxEvents = 8,
				maxQueuedBytes = 10000,
				MeasureRecord = function(commit: NetworkingTypes.PublicationFilteredCommit): number
					local size: number?, reason: string? = fixture.stream.codec.Measure({
						{
							kind = "Commit",
							handle = 1,
							revision = commit.sequence,
							patches = commit.patches,
							events = commit.events,
						},
					})

					assert(size ~= nil, reason)

					return size
				end,
			})

			scheduler = queue
			local stream: NetworkingTypes.PublicationStreamKey = { recipient = "Client", actor = actor }
			queue:ResetAfterBaseline(stream, baseline.domains)
			local results: { any } = {}

			TestUtils.publication():ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
				local accepted: boolean, reason: string? = queue:Enqueue(
					stream,
					{ sequence = commit.sequence, patches = commit.patches, events = commit.events }
				)

				table.insert(results, { accepted = accepted, reason = reason })
			end)

			TestUtils.accept(actions, "Visible", { private = "NeverSerialize" })
			expect(results).toEqual({ { accepted = true }, { accepted = true } })
			expect(queue:GetStreamStatus(stream).pendingEvents).toBe(2)
			local drained: NetworkingTypes.PublicationDrainResult = queue:DrainBudgeted(10000, 8)
			expect(#drained.records).toBe(2)
			local records: { SharedTypes.ActorStreamRecord } = {}

			for _, record: NetworkingTypes.PublicationRecord in drained.records do
				local encodedRecord: SharedTypes.ActorStreamRecord = {
					kind = "Commit",
					handle = 1,
					revision = record.commit.sequence,
					patches = record.commit.patches,
					events = record.commit.events,
				}

				table.insert(records, encodedRecord)
			end

			ActorUtils.send(fixture, records)

			expect(history).toEqual({
				{ "Started", { actionId = "Visible", sequenceId = 1 } },
				{ terminal, { actionId = "Visible", sequenceId = 1 } },
			})

			expect(view:GetActiveActions()).toEqual({})
			expect(queue:GetStreamStatus(stream).pendingEvents).toBe(0)
			expect(fixture.faults).toEqual({})
			expect(fixture.requests).toEqual({})
		end
	)
end

it("installs real accepted Resource, Tag and Action truth before the typed Started Fire", function()
	local definition: ActionTypes.ActionDefinition = TestUtils.action("Visible")
	definition.costs = { Mana = 20 }
	definition.activeTags = { "Incoming" }
	TestUtils.initialize({ definition })
	local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
	TestUtils.domain()
	assert(prepared ~= nil, "Expected staged native protocol")
	local fixture: ActorUtils.Fixture = ActorUtils.new(nil, prepared.manifest)
	client = fixture
	local baseline: NetworkingTypes.PublicationBaseline? = TestUtils.publication():CaptureBaseline(actor)
	assert(baseline ~= nil, "Expected server baseline")
	ActorUtils.baseline(fixture, 1, actor:GetId(), 0, baseline.domains)
	local actorView: ClientTypes.ActorView = ActorUtils.view(fixture, actor:GetId())
	local view: ViewUtils.ActionsView = ViewUtils.get(actorView)
	local startedSignal: any = nil

	GoodSignal.Connect = function(self: any, callback: any): any
		startedSignal = self

		return originalConnect(self, callback)
	end

	view.OnActionStarted:Connect(function() end)
	GoodSignal.Connect = originalConnect

	local atFire: { any } = {}

	GoodSignal.Fire = function(self: any, ...: any)
		if self == startedSignal then
			table.insert(atFire, {
				action = view:GetAction(1),
				mana = actorView:GetResources():GetCurrent("Mana"),
				casting = actorView:GetTags():HasTag("Incoming"),
			})
		end

		originalFire(self, ...)
	end

	local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
	TestUtils.accept(actions, "Visible")
	expect(#commits).toBe(1)
	ActorUtils.commit(fixture, 1, commits[1].patches, commits[1].events)
	expect(atFire).toEqual({ { action = { actionId = "Visible", sequenceId = 1 }, mana = 80, casting = true } })
	expect(fixture.faults).toEqual({})
end)
