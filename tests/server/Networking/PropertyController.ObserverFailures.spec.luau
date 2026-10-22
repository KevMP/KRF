--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local PropertyTypes = require(KRF.server.Property.types)
local ResourceTypes = require(KRF.server.Resource.types)
local ActorTypes = require(KRF.server.Actor.types)
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

for _, source: string in { "Property", "Tag" } do
	for _, phase: string in { "Commit", "Dispatch" } do
		for _, failureKind: string in { "Throw", "Yield" } do
			it(
				`completes {source} authority and notifications after Property {phase} observer {failureKind}`,
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
							duplicateBehavior = "Ignore",
							properties = { MaxMana = { multiply = 0.5 } },
						},
					})

					local actor: ActorTypes.Actor, _, resources: ResourceTypes.ResourceController, publicProperties: PropertyTypes.PropertyController, tags: TagTypes.TagController =
						ActionUtils.registerActor()

					local properties: PropertyTypes.InternalPropertyController =
						publicProperties :: PropertyTypes.InternalPropertyController

					local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
					local order: { string } = {}
					local publicTruth: { number } = {}

					table.insert(
						connections,
						tags.OnTagAdded:Connect(function()
							table.insert(order, "TagAdded")
						end)
					)

					table.insert(
						connections,
						tags.OnTagChanged:Connect(function()
							table.insert(order, "TagChanged")
						end)
					)

					table.insert(
						connections,
						properties.OnBasePropertyChanged:Connect(function()
							table.insert(order, "Base")
						end)
					)

					table.insert(
						connections,
						properties.OnResolvedPropertyChanged:Connect(function()
							local baseline: NetworkingTypes.PublicationBaseline? = TestUtils.publication()
								:CaptureBaseline(actor)

							assert(baseline ~= nil, "Expected retained publication")
							table.insert(publicTruth, baseline.domains["KRF.Resources"].value.Mana.max)
							table.insert(order, "Resolved")
						end)
					)

					table.insert(
						connections,
						properties.OnPropertyChanged:Connect(function()
							table.insert(order, "Property")
						end)
					)

					table.insert(
						connections,
						resources.OnResourceChanged:Connect(function()
							table.insert(order, "Resource")
						end)
					)

					local failures: { {} } = {}
					local suspended: { thread } = {}
					local resumed: boolean = false
					local commitCalls: number = 0
					local dispatchCalls: number = 0

					for index = 1, 3 do
						local original = { observer = index }

						local function fail(): ()
							table.insert(failures, original)

							if failureKind == "Throw" then
								error(original, 0)
							end

							table.insert(suspended, coroutine.running())
							coroutine.yield()
							resumed = true
						end

						table.insert(
							disconnects,
							properties:_observeResolvedMutations({
								Commit = function(names: { string }): ()
									commitCalls += 1
									expect(names).toEqual({ "MaxMana" })

									if phase == "Commit" then
										fail()
									end
								end,
								Dispatch = function(): ()
									dispatchCalls += 1

									if phase == "Dispatch" then
										fail()
									end
								end,
							})
						)
					end

					local success: boolean = true
					local failure: any = nil

					local transaction: thread = coroutine.create(function(): ()
						success, failure = pcall(function(): ()
							if source == "Property" then
								properties:SetBaseProperty("MaxMana", 50)
							else
								tags:AddTag("Capacity")
							end
						end)
					end)

					expect(coroutine.resume(transaction)).toBe(true)
					local status: string = coroutine.status(transaction)

					if status ~= "dead" then
						coroutine.close(transaction)
					end

					expect(status).toBe("dead")
					expect(success).toBe(false)

					expect(failure).toBe(
						if failureKind == "Throw" then failures[1] else "PropertyMutationObserverYielded"
					)

					expect(commitCalls).toBe(3)
					expect(dispatchCalls).toBe(3)
					expect(#failures).toBe(3)
					expect(resumed).toBe(false)

					for _, observerThread: thread in suspended do
						expect(coroutine.status(observerThread)).toBe("dead")
					end

					expect(properties:GetBaseProperty("MaxMana")).toBe(if source == "Property" then 50 else 100)
					expect(properties:GetResolvedProperty("MaxMana")).toBe(50)
					expect(resources:GetMax("Mana")).toBe(50)
					expect(resources:GetCurrent("Mana")).toBe(50)
					expect(publicTruth).toEqual({ 50 })

					expect(order).toEqual(
						if source == "Property"
							then { "Base", "Resolved", "Property", "Resource" }
							else { "TagAdded", "TagChanged", "Resolved", "Property", "Resource" }
					)

					expect(#commits).toBe(if source == "Property" then 1 else 2)

					for _, disconnect in disconnects do
						disconnect()
					end

					table.clear(order)
					table.clear(commits)

					expect(
						if source == "Property"
							then properties:SetBaseProperty("MaxMana", 80)
							else tags:RemoveTag("Capacity")
					).toBe(true)

					expect(resources:GetCurrent("Mana")).toBe(50)
					expect(resources:GetMax("Mana")).toBe(if source == "Property" then 80 else 100)
					expect(commitCalls).toBe(3)
					expect(dispatchCalls).toBe(3)
					expect(publicTruth).toEqual({ 50, if source == "Property" then 80 else 100 })
					expect(#commits).toBe(if source == "Property" then 1 else 2)

					expect(order).toEqual(
						if source == "Property"
							then { "Base", "Resolved", "Property", "Resource" }
							else { "TagChanged", "Resolved", "Property", "Resource" }
					)
				end
			)
		end
	end
end

for _, source: string in { "Property", "Tag" } do
	it(`retains the original derived Resource failure before {source} public reentry drains notifications`, function()
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
				duplicateBehavior = "Ignore",
				properties = { MaxMana = { multiply = 0.5 } },
			},
		})

		local actor: ActorTypes.Actor, _, publicResources: ResourceTypes.ResourceController, properties: PropertyTypes.PropertyController, tags: TagTypes.TagController =
			ActionUtils.registerActor()

		local resources: ResourceTypes.InternalResourceController =
			publicResources :: ResourceTypes.InternalResourceController

		local original = { reason = "CommittedResourceFailure" }
		local first: boolean = true
		local nestedSuccess: boolean? = nil
		local nestedFailure: any = nil
		local changes: { ResourceTypes.ResourceChange } = {}
		local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()

		table.insert(
			disconnects,
			resources:_observeMutations({
				Commit = function(): ()
					if first then
						first = false
						error(original, 0)
					end
				end,
				Dispatch = function(): () end,
			})
		)

		table.insert(
			connections,
			properties.OnResolvedPropertyChanged:Connect(function(): ()
				nestedSuccess, nestedFailure = pcall(function(): ()
					expect(resources:SetCurrent("Mana", 40)).toBe(true)
				end)
			end)
		)

		table.insert(
			connections,
			resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange): ()
				table.insert(changes, change)
			end)
		)

		local success: boolean, failure: any = pcall(function(): ()
			if source == "Property" then
				properties:SetBaseProperty("MaxMana", 50)
			else
				tags:AddTag("Capacity")
			end
		end)

		expect(success).toBe(false)
		expect(failure).toBe(original)
		expect(nestedSuccess).toBe(true)
		expect(nestedFailure).toBeNil()
		expect(resources:GetCurrent("Mana")).toBe(40)
		expect(resources:GetMax("Mana")).toBe(50)
		expect(properties:GetResolvedProperty("MaxMana")).toBe(50)
		expect(#changes).toBe(2)
		expect(changes[1].currentOldValue).toBe(100)
		expect(changes[1].currentNewValue).toBe(50)
		expect(changes[2].currentOldValue).toBe(50)
		expect(changes[2].currentNewValue).toBe(40)
		expect(#commits).toBe(if source == "Property" then 2 else 3)
		local baseline: NetworkingTypes.PublicationBaseline? = TestUtils.publication():CaptureBaseline(actor)
		assert(baseline ~= nil, "Expected current committed truth")
		expect(baseline.sequence).toBe(#commits)
		expect(baseline.domains["KRF.Resources"].value.Mana.anchorValue).toBe(40)
		expect(resources:Spend("Mana", 1)).toBe(true)
		expect(resources:GetCurrent("Mana")).toBe(39)
		expect(#changes).toBe(3)
	end)
end
