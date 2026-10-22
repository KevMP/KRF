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
local ResourceTypes = require(KRF.server.Resource.types)
local PropertyTypes = require(KRF.server.Property.types)
local TagTypes = require(KRF.server.Tags.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActionsReplicationTestUtils)

local disconnects: { () -> () } = {}
local connections: { SignalTypes.Connection } = {}

beforeEach(function()
	ActionUtils.reset()
	disconnects = {}
	connections = {}
end)

afterEach(function()
	for _, connection: SignalTypes.Connection in connections do
		connection:Disconnect()
	end

	for _, disconnect in disconnects do
		disconnect()
	end

	ActionUtils.cleanup()
end)

for _, failureKind: string in { "Throw", "Yield" } do
	it(
		"finishes all eligible private Tag Dispatch observers after "
			.. failureKind
			.. " and propagates the first failure",
		function()
			local order: { string } = {}

			local definition: ActionTypes.ActionDefinition = TestUtils.action("Cast")
			definition.costs = { Mana = 20 }
			definition.activeTags = { "Capacity" }

			definition.onStart = function()
				table.insert(order, "StartHook")
			end

			definition.onEnd = function()
				table.insert(order, "EndHook")
			end

			ActionUtils.initialize({ definition }, {
				{
					id = "Mana",
					visibility = "ClientVisible",
					autoAssign = true,
					initialValue = 100,
					max = { value = 100 },
				},
			}, {
				{
					id = "Capacity",
					visibility = "ClientVisible",
					duplicateBehavior = "Ignore",
					properties = { WalkSpeed = { set = 8 } },
				},
			})

			local actor: ActorTypes.Actor, actions: ActionTypes.ActionController, resources: ResourceTypes.ResourceController, properties: PropertyTypes.PropertyController, publicTags: TagTypes.TagController =
				ActionUtils.registerActor()

			local tags: TagTypes.InternalTagController = publicTags :: TagTypes.InternalTagController
			local publication: NetworkingTypes.PublicationRuntime = TestUtils.publication()
			local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
			local lifecycleTruth: { NetworkingTypes.PublicationBaseline } = {}

			table.insert(
				connections,
				actions.OnActionStarted:Connect(function()
					local baseline: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
					assert(baseline ~= nil, "Expected retained Actor publication")
					table.insert(lifecycleTruth, baseline)
					table.insert(order, "Started")
				end)
			)

			table.insert(
				connections,
				actions.OnActionEnded:Connect(function()
					table.insert(order, "Ended")
				end)
			)

			table.insert(
				connections,
				tags.OnTagAdded:Connect(function()
					table.insert(order, "TagAdded")
				end)
			)

			table.insert(
				connections,
				tags.OnTagRemoved:Connect(function()
					table.insert(order, "TagRemoved")
				end)
			)

			table.insert(
				connections,
				properties.OnResolvedPropertyChanged:Connect(
					function(_actor: ActorTypes.Actor, id: string, old: number?, new: number)
						table.insert(order, `{id}:{old}->{new}`)
					end
				)
			)

			table.insert(
				connections,
				resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange)
					table.insert(order, `Mana:{change.currentOldValue}->{change.currentNewValue}`)
				end)
			)

			local failures: { { observer: number } } = {}
			local suspended: { thread } = {}
			local continued: boolean = false

			for index = 1, 3 do
				local value = { observer = index }

				table.insert(
					disconnects,
					tags:_observeMutations({
						Commit = function() end,
						Dispatch = function()
							table.insert(failures, value)

							if failureKind == "Throw" then
								error(value, 0)
							end

							table.insert(suspended, coroutine.running())
							coroutine.yield()
							continued = true
						end,
					})
				)
			end

			local healthyDispatches: number = 0

			table.insert(
				disconnects,
				tags:_observeMutations({
					Commit = function() end,
					Dispatch = function()
						healthyDispatches += 1
					end,
				})
			)

			local success: boolean, failure: any = pcall(function()
				actions:RequestAction("Cast")
			end)

			expect(success).toBe(false)
			expect(failure).toBe(if failureKind == "Throw" then failures[1] else "TagMutationObserverYielded")
			expect(#failures).toBe(3)
			expect(healthyDispatches).toBe(1)
			expect(continued).toBe(false)

			for _, observerThread: thread in suspended do
				expect(coroutine.status(observerThread)).toBe("dead")
			end

			expect(order).toEqual({ "Started", "TagAdded", "WalkSpeed:16->8", "Mana:100->80", "StartHook" })
			expect(resources:GetCurrent("Mana")).toBe(80)
			expect(properties:GetResolvedProperty("WalkSpeed")).toBe(8)
			expect(tags:HasTag("Capacity")).toBe(true)

			expect(TestUtils.internal(actions):_getActiveReplicationState()).toEqual({
				{ actionId = "Cast", sequenceId = 1 },
			})

			local baseline: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
			assert(baseline ~= nil, "Expected admitted Actor publication")
			expect(baseline.sequence).toBe(1)
			expect(baseline.domains["KRF.Actions"].value).toEqual({ [1] = "Cast" })
			expect(baseline.domains["KRF.Tags"].value).toEqual({ Capacity = { stackCount = 1 } })
			expect(baseline.domains["KRF.Resources"].value.Mana.anchorValue).toBe(80)
			expect(lifecycleTruth).toEqual({ baseline })
			expect(#commits).toBe(1)

			expect(TestUtils.events(commits[1])).toEqual({
				{ domainId = "KRF.Actions", eventId = "Started", payload = { actionId = "Cast", sequenceId = 1 } },
			})

			for index = 1, 3 do
				disconnects[index]()
			end

			table.clear(order)
			table.clear(commits)
			expect(actions:EndAction(1)).toBe(true)
			expect(order).toEqual({ "Ended", "TagRemoved", "WalkSpeed:8->16", "EndHook" })
			expect(healthyDispatches).toBe(2)
			expect(#failures).toBe(3)
			expect(resources:GetCurrent("Mana")).toBe(80)
			expect(TestUtils.state(actor)).toEqual({})
			expect(#commits).toBe(1)
			expect(commits[1].sequence).toBe(2)

			expect(TestUtils.events(commits[1])).toEqual({
				{ domainId = "KRF.Actions", eventId = "Ended", payload = { actionId = "Cast", sequenceId = 1 } },
			})
		end
	)
end
