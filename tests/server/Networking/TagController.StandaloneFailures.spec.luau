--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)
local ResourceTypes = require(KRF.server.Resource.types)
local PropertyTypes = require(KRF.server.Property.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local TagController = require(KRF.server.Tags.TagController)
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

for _, operation: string in { "Added", "Removed", "SingleRemoved", "Refreshed", "Expired" } do
	for _, failureKind: string in { "Throw", "Yield" } do
		it(`finishes standalone Tag {operation} delivery after a private Commit observer {failureKind}`, function()
			local eventKind: string = if operation == "SingleRemoved" then "Removed" else operation

			ActionUtils.initialize({}, {
				{
					id = "Mana",
					visibility = "ClientVisible",
					autoAssign = true,
					initialValue = 100,
					max = { propertyName = "MaxMana", defaultBaseValue = 100 },
				},
			}, {
				{
					id = "Capacity",
					visibility = "ClientVisible",
					duplicateBehavior = if operation == "SingleRemoved" then "Stack" else "Refresh",
					properties = { MaxMana = { set = 50 } },
				},
			})

			local actor: ActorTypes.Actor, _, resources: ResourceTypes.ResourceController, properties: PropertyTypes.PropertyController, publicTags: TagTypes.TagController =
				ActionUtils.registerActor()

			local tags: TagTypes.InternalTagController = publicTags :: TagTypes.InternalTagController

			if operation ~= "Added" then
				expect(tags:AddTag("Capacity", { duration = 1 })).toBe(true)
			end

			if operation == "SingleRemoved" then
				expect(tags:AddTag("Capacity", { duration = 2 })).toBe(true)
			end

			local publication: NetworkingTypes.PublicationRuntime = TestUtils.publication()
			local before: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
			assert(before ~= nil, "Expected admitted Actor")
			local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
			local order: { string } = {}
			local publicTruth: { { hasTag: boolean, maximum: number?, property: number?, sequence: number } } = {}

			local function onTag(_actor: ActorTypes.Actor, _id: string): ()
				local baseline: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
				assert(baseline ~= nil, "Expected retained publication")

				table.insert(publicTruth, {
					hasTag = tags:HasTag("Capacity"),
					maximum = baseline.domains["KRF.Resources"].value.Mana.max,
					property = properties:GetResolvedProperty("MaxMana"),
					sequence = baseline.sequence,
				})

				table.insert(order, eventKind)
			end

			local specific: SignalTypes.Event<ActorTypes.Actor, string> = if eventKind == "Added"
				then tags.OnTagAdded
				elseif eventKind == "Removed" then tags.OnTagRemoved
				elseif eventKind == "Refreshed" then tags.OnTagRefreshed
				else tags.OnTagExpired

			table.insert(connections, specific:Connect(onTag))

			table.insert(
				connections,
				tags.OnTagChanged:Connect(function()
					table.insert(order, "Changed")
				end)
			)

			table.insert(
				connections,
				properties.OnResolvedPropertyChanged:Connect(function()
					table.insert(order, "Property")
				end)
			)

			table.insert(
				connections,
				resources.OnResourceChanged:Connect(function(_change: ResourceTypes.ResourceChange)
					table.insert(order, "Resource")
				end)
			)

			local failures: { {} } = {}
			local suspended: { thread } = {}
			local resumed: boolean = false
			local dispatches: number = 0

			for index = 1, 3 do
				local original = { observer = index }

				table.insert(
					disconnects,
					tags:_observeMutations({
						Commit = function(events: { TagTypes.TagMutationEvent }): ()
							expect(events).toEqual({ { kind = eventKind, tagId = "Capacity" } })
							table.insert(failures, original)

							if failureKind == "Throw" then
								error(original, 0)
							end

							table.insert(suspended, coroutine.running())
							coroutine.yield()
							resumed = true
						end,
						Dispatch = function(): ()
							dispatches += 1
							error("LaterDispatchFailure", 0)
						end,
					})
				)
			end

			local success: boolean, failure: any = pcall(function()
				if operation == "Added" then
					tags:AddTag("Capacity")
				elseif operation == "Removed" then
					tags:RemoveTag("Capacity")
				elseif operation == "SingleRemoved" then
					tags:RemoveSingleTag("Capacity")
				elseif operation == "Refreshed" then
					tags:AddTag("Capacity", { duration = 5 })
				else
					TagController.Step(1)
				end
			end)

			expect(success).toBe(false)
			expect(failure).toBe(if failureKind == "Throw" then failures[1] else "TagMutationObserverYielded")
			expect(#failures).toBe(3)
			expect(dispatches).toBe(3)
			expect(resumed).toBe(false)

			for _, observerThread: thread in suspended do
				expect(coroutine.status(observerThread)).toBe("dead")
			end

			local active: boolean = operation == "Added" or operation == "Refreshed" or operation == "SingleRemoved"
			local maximum: number = if active then 50 else 100
			local derivedChanged: boolean = operation ~= "Refreshed" and operation ~= "SingleRemoved"
			local expectedCommits: number = if derivedChanged then 2 else 1
			expect(tags:HasTag("Capacity")).toBe(active)
			expect(#tags:GetTagInstances("Capacity")).toBe(if active then 1 else 0)
			expect(properties:GetResolvedProperty("MaxMana")).toBe(maximum)
			expect(resources:GetCurrent("Mana")).toBe(50)
			expect(resources:GetMax("Mana")).toBe(maximum)

			expect(order).toEqual(
				if derivedChanged then { eventKind, "Changed", "Property", "Resource" } else { eventKind, "Changed" }
			)

			expect(#commits).toBe(expectedCommits)

			expect(publicTruth).toEqual({
				{
					hasTag = active,
					maximum = maximum,
					property = maximum,
					sequence = before.sequence + expectedCommits,
				},
			})

			local events: { NetworkingTypes.PublicationEvent } = {}

			for index, commit: NetworkingTypes.PublicationCommit in commits do
				expect(commit.sequence).toBe(before.sequence + index)

				for _, event: NetworkingTypes.PublicationEvent in commit.events do
					table.insert(events, event)
				end
			end

			expect(events).toEqual({ { domainId = "KRF.Tags", eventId = eventKind, payload = "Capacity" } })
			local after: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
			assert(after ~= nil, "Expected committed publication")
			expect(after.domains["KRF.Resources"].value.Mana.anchorValue).toBe(50)
			expect(after.domains["KRF.Tags"].value.Capacity ~= nil).toBe(active)

			if operation == "Refreshed" then
				expect(tags:GetTagInstances("Capacity")[1].remainingDuration).toBe(5)

				expect(after.domains["KRF.Tags"].value.Capacity.expiresAt).toBeGreaterThan(
					before.domains["KRF.Tags"].value.Capacity.expiresAt
				)
			end

			for _, disconnect in disconnects do
				disconnect()
			end

			table.clear(commits)
			table.clear(order)
			expect(if active then tags:RemoveTag("Capacity") else tags:AddTag("Capacity")).toBe(true)
			expect(#failures).toBe(3)
			expect(dispatches).toBe(3)
			expect(#commits).toBe(2)
			expect(commits[2].sequence).toBe(after.sequence + 2)
			local recoveredEvents: { NetworkingTypes.PublicationEvent } = {}

			for _, commit: NetworkingTypes.PublicationCommit in commits do
				for _, event: NetworkingTypes.PublicationEvent in commit.events do
					table.insert(recoveredEvents, event)
				end
			end

			expect(recoveredEvents).toEqual({
				{ domainId = "KRF.Tags", eventId = if active then "Removed" else "Added", payload = "Capacity" },
			})

			expect(resources:GetCurrent("Mana")).toBe(50)
		end)
	end
end
