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
local PropertyTypes = require(KRF.server.Property.types)
local ResourceTypes = require(KRF.server.Resource.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SignalTypes = require(KRF.shared.Signal.types)
local TagRegistry = require(KRF.server.Tags.TagRegistry)
local ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)

local Domains: ReplicationTypes.InternalReplicationDomainRegistry =
	require(KRF.server.Replication.ReplicationDomainRegistry)

local TagsReplication = require(KRF.server.Networking.utils.TagsReplication)
local ResourcesReplication = require(KRF.server.Networking.utils.ResourcesReplication)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActionsReplicationTestUtils)
local PublicationUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)

local runtime: NetworkingTypes.PublicationRuntime? = nil
local connections: { SignalTypes.Connection } = {}

beforeEach(function()
	ActionUtils.reset()
	connections = {}
end)

afterEach(function()
	for _, connection: SignalTypes.Connection in connections do
		connection:Disconnect()
	end

	if runtime ~= nil then
		runtime:Destroy()
		runtime = nil
	end

	ActionUtils.cleanup()
end)

for _, rejected: boolean in { true, false } do
	it(
		`distinguishes standalone Tag publication rejection from admitted observer failure, rejected={rejected}`,
		function()
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
					duplicateBehavior = "Refresh",
					properties = { MaxMana = { set = 50 } },
				},
			})

			local actor: ActorTypes.Actor, _, resources: ResourceTypes.ResourceController, properties: PropertyTypes.PropertyController, tags: TagTypes.TagController =
				ActionUtils.registerActor()

			-- Use the actual producers, with only the Tag producer's clock controlled.
			TestUtils.publication():DetachActor(actor)
			local now: number = 1000

			local tagDomain = TagsReplication.Build(TagRegistry.GetAll(), function(): number
				return now
			end)

			local resourceDomain = ResourcesReplication.Build(ResourceRegistry.GetAll())
			assert(tagDomain ~= nil and resourceDomain ~= nil, "Expected visible built-in domains")

			-- The installed runtime retains its compiled catalog; compile fresh adapters
			-- independently, matching the existing late-attachment integration fixtures.
			Domains._resetForTests()

			local publication: NetworkingTypes.PublicationRuntime =
				PublicationUtils.createRuntime({ tagDomain, resourceDomain })

			runtime = publication
			expect(publication:AttachActor(actor)).toBe(true)
			local original = { reason = "AdmittedObserverFailure" }
			local commits: { NetworkingTypes.PublicationCommit } = {}
			local order: { string } = {}
			local publicTruth: NetworkingTypes.PublicationBaseline? = nil

			publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit): ()
				table.insert(commits, commit)
			end)

			local disconnect: () -> () = publication:ObserveCommits(
				function(commit: NetworkingTypes.PublicationCommit): ()
					if not rejected and #commit.events > 0 then
						error(original, 0)
					end
				end
			)

			table.insert(
				connections,
				tags.OnTagAdded:Connect(function(): ()
					publicTruth = publication:CaptureBaseline(actor)
					table.insert(order, "Added")
				end)
			)

			table.insert(
				connections,
				tags.OnTagRefreshed:Connect(function(): ()
					table.insert(order, "Refreshed")
				end)
			)

			table.insert(
				connections,
				tags.OnTagChanged:Connect(function(): ()
					table.insert(order, "Changed")
				end)
			)

			table.insert(
				connections,
				properties.OnResolvedPropertyChanged:Connect(function(): ()
					table.insert(order, "Property")
				end)
			)

			table.insert(
				connections,
				resources.OnResourceChanged:Connect(function(): ()
					table.insert(order, "Resource")
				end)
			)

			now = if rejected then math.huge else 1000

			local success: boolean, failure: any = pcall(function(): ()
				tags:AddTag("Capacity", { duration = 10 })
			end)

			expect(success).toBe(false)
			expect(failure).toBe(if rejected then "InvalidPublicationSnapshot:KRF.Tags" else original)
			expect(tags:HasTag("Capacity")).toBe(true)
			expect(tags:GetTagInstances("Capacity")[1].remainingDuration).toBe(10)
			expect(properties:GetResolvedProperty("MaxMana")).toBe(50)
			expect(resources:GetMax("Mana")).toBe(50)
			expect(resources:GetCurrent("Mana")).toBe(50)
			expect(order).toEqual({ "Added", "Changed", "Property", "Resource" })
			local baseline: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
			assert(baseline ~= nil, "Expected retained canonical truth")
			expect(publicTruth).toEqual(baseline)
			expect(baseline.sequence).toBe(if rejected then 1 else 2)

			expect(baseline.domains["KRF.Tags"].value).toEqual(
				if rejected then {} else { Capacity = { stackCount = 1, expiresAt = 1010 } }
			)

			expect(baseline.domains["KRF.Resources"].value.Mana.anchorValue).toBe(50)
			expect(#commits).toBe(baseline.sequence)
			disconnect()
			now = 1002
			table.clear(order)
			table.clear(commits)
			expect(tags:AddTag("Capacity", { duration = 20 })).toBe(true)
			expect(order).toEqual({ "Refreshed", "Changed" })
			expect(#commits).toBe(1)
			expect(commits[1].sequence).toBe(baseline.sequence + 1)

			expect(commits[1].events).toEqual({
				{ domainId = "KRF.Tags", eventId = "Refreshed", payload = "Capacity" },
			})

			local recovered: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
			assert(recovered ~= nil, "Expected reconciled truth")
			expect(recovered.domains["KRF.Tags"].value).toEqual({ Capacity = { stackCount = 1, expiresAt = 1022 } })
			expect(resources:GetCurrent("Mana")).toBe(50)
		end
	)
end
