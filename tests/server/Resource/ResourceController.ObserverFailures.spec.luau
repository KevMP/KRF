--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ResourceTypes = require(KRF.server.Resource.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ResourcesReplicationTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

it("reports rejected publication after draining authoritative notifications and recovers without replay", function()
	local publication: NetworkingTypes.PublicationRuntime = TestUtils.attach(fixture)
	local baseline: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(fixture.actor)
	local changes: { { number } } = {}

	fixture.resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange)
		table.insert(changes, { change.currentOldValue, change.currentNewValue })
	end)

	fixture.clock.now = math.huge

	local success: boolean, failure: any = pcall(function()
		fixture.resources:Spend("Resource.Mana", 5)
	end)

	expect(success).toBe(false)
	expect(failure).toBe("PublicationSnapshotError:KRF.Resources")
	expect(fixture.resources:GetCurrent("Resource.Mana")).toBe(35)
	expect(publication:CaptureBaseline(fixture.actor)).toEqual(baseline)
	expect(changes).toEqual({ { 40, 35 } })
	fixture.resources:_dispatchChanges()
	expect(changes).toEqual({ { 40, 35 } })
	fixture.clock.now = 1001
	expect(fixture.resources:Spend("Resource.Mana", 1)).toBe(true)
	expect(changes).toEqual({ { 40, 35 }, { 35, 34 } })
	expect(#fixture.commits).toBe(1)
	local recovered: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(fixture.actor)
	assert(recovered ~= nil, "Expected retained attachment")
	expect(recovered.sequence).toBe(1)
	expect(recovered.domains["KRF.Resources"].value["Resource.Mana"].anchorValue).toBe(34)
end)

it(
	"retains admitted canonical state when a downstream N3 observer fails and preserves the original error value",
	function()
		local publication: NetworkingTypes.PublicationRuntime = TestUtils.attach(fixture)
		local failureValue = { reason = "DownstreamCommitFailure" }

		local disconnect = publication:ObserveCommits(function()
			error(failureValue, 0)
		end)

		local changes: { number } = {}

		fixture.resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange)
			table.insert(changes, change.currentNewValue)
		end)

		local success: boolean, failure: any = pcall(function()
			fixture.resources:Spend("Resource.Mana", 5)
		end)

		expect(success).toBe(false)
		expect(failure).toBe(failureValue)
		expect(fixture.resources:GetCurrent("Resource.Mana")).toBe(35)
		expect(changes).toEqual({ 35 })
		local admitted: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(fixture.actor)
		assert(admitted ~= nil, "Expected retained canonical state")
		expect(admitted.sequence).toBe(1)
		expect(admitted.domains["KRF.Resources"].value["Resource.Mana"].anchorValue).toBe(35)
		disconnect()
		fixture.resources:Spend("Resource.Mana", 1)
		expect(changes).toEqual({ 35, 34 })
		expect(publication:GetActorSequence(fixture.actor)).toBe(2)
		expect(#fixture.commits).toBe(2)
		fixture.resources:_dispatchChanges()
		expect(changes).toEqual({ 35, 34 })
	end
)

it("finishes private commits before public callbacks despite failure and nested authority changes", function()
	local order: { string } = {}
	local nested: boolean = false

	local disconnect = fixture.resources:_observeMutations({
		Commit = function()
			table.insert(order, "Commit")

			if not nested then
				nested = true
				fixture.resources:Spend("Resource.Mana", 1)
			end

			error("ObserverFailure", 0)
		end,
		Dispatch = function()
			table.insert(order, "Dispatch")
		end,
	})

	fixture.resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange)
		table.insert(order, tostring(change.currentNewValue))
	end)

	local success: boolean, failure: any = pcall(function()
		fixture.resources:Spend("Resource.Mana", 5)
	end)

	expect(success).toBe(false)
	expect(failure).toBe("ObserverFailure")
	expect(order).toEqual({ "Commit", "Commit", "35", "34", "Dispatch" })
	disconnect()
	disconnect()
	expect(fixture.resources:Spend("Resource.Mana", 1)).toBe(true)
	expect(order).toEqual({ "Commit", "Commit", "35", "34", "Dispatch", "33" })
end)

it("retains batch notification order and reports a commit error at dispatch exactly once", function()
	local changes: { number } = {}

	fixture.resources:_observeMutations({
		Commit = function()
			error("BatchObserverFailure", 0)
		end,
		Dispatch = function() end,
	})

	fixture.resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange)
		table.insert(changes, change.currentNewValue)
	end)

	fixture.resources:_beginMutationBatch()
	fixture.resources:Spend("Resource.Mana", 5)
	fixture.resources:_finishMutationBatch()
	expect(changes).toEqual({})

	local success: boolean, failure: any = pcall(function()
		fixture.resources:_dispatchChanges()
	end)

	expect(success).toBe(false)
	expect(failure).toBe("BatchObserverFailure")
	expect(changes).toEqual({ 35 })
	fixture.resources:_dispatchChanges()
	expect(changes).toEqual({ 35 })
end)

for _, phase: string in { "Commit", "Dispatch" } do
	it("continues eligible observers after a failing " .. phase .. " and honors disconnection", function()
		local commits: number = 0
		local dispatches: number = 0
		local disconnects: { () -> () } = {}

		for _ = 1, 3 do
			local disconnect: () -> ()

			disconnect = fixture.resources:_observeMutations({
				Commit = function()
					commits += 1

					if phase == "Commit" then
						disconnect()
						error("PrivateFailure", 0)
					end
				end,
				Dispatch = function()
					dispatches += 1
					disconnect()
					error("PrivateFailure", 0)
				end,
			})

			table.insert(disconnects, disconnect)
		end

		local success: boolean, failure: any = pcall(function()
			fixture.resources:Spend("Resource.Mana", 1)
		end)

		expect(success).toBe(false)
		expect(failure).toBe("PrivateFailure")
		expect(commits).toBe(3)
		expect(dispatches).toBe(if phase == "Commit" then 0 else 3)
		expect(fixture.resources:Spend("Resource.Mana", 1)).toBe(true)

		for _, disconnect in disconnects do
			disconnect()
		end
	end)
end

it("preserves Property notifications and recomputed Resource authority when publication fails", function()
	TestUtils.attach(fixture)
	local order: { string } = {}

	fixture.properties.OnResolvedPropertyChanged:Connect(function()
		table.insert(order, "Property")
	end)

	fixture.resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange)
		table.insert(order, "Resource:" .. tostring(change.currentNewValue))
	end)

	fixture.clock.now = math.huge

	local success: boolean, failure: any = pcall(function()
		fixture.properties:SetBaseProperty("ManaMax", 30)
	end)

	expect(success).toBe(false)
	expect(failure).toBe("PublicationSnapshotError:KRF.Resources")
	expect(order).toEqual({ "Property", "Resource:30" })
	expect(fixture.resources:GetMax("Resource.Mana")).toBe(30)
	expect(fixture.resources:GetCurrent("Resource.Mana")).toBe(30)
	fixture.clock.now = 1001
	expect(fixture.properties:SetBaseProperty("ManaMax", 50)).toBe(true)
	expect(order).toEqual({ "Property", "Resource:30", "Property", "Resource:30" })
end)

it("reports failure even if its observer tears down authority and suppresses pending notifications", function()
	local notifications: number = 0

	fixture.resources.OnResourceChanged:Connect(function()
		notifications += 1
	end)

	fixture.resources:_observeMutations({
		Commit = function()
			fixture.resources:Destroy()
			error("TeardownFailure", 0)
		end,
		Dispatch = function()
			error("Destroyed observer dispatched")
		end,
	})

	local success: boolean, failure: any = pcall(function()
		fixture.resources:Spend("Resource.Mana", 1)
	end)

	expect(success).toBe(false)
	expect(failure).toBe("TeardownFailure")
	expect(notifications).toBe(0)
	expect(fixture.resources:GetCurrent("Resource.Mana")).toBeNil()
	fixture.resources:_dispatchChanges()
end)

it(
	"delivers failed assignment exactly once before subsequent reentrant changes and preserves the first error",
	function()
		TestUtils.attach(fixture)
		local order: { string } = {}

		fixture.resources.OnResourceAdded:Connect(function(_actor, id: string)
			table.insert(order, "Added:" .. id)
			fixture.clock.now = 1001
			fixture.resources:Spend(id, 1)
		end)

		fixture.resources.OnResourceChanged:Connect(function(change: ResourceTypes.ResourceChange)
			table.insert(order, tostring(change.currentNewValue))
		end)

		fixture.clock.now = math.huge

		local success: boolean, failure: any = pcall(function()
			fixture.resources:AddResource("Resource.Rage", 20)
		end)

		expect(success).toBe(false)
		expect(failure).toBe("PublicationSnapshotError:KRF.Resources")
		expect(order).toEqual({ "Added:Resource.Rage", "19" })
		expect(fixture.resources:GetCurrent("Resource.Rage")).toBe(19)
		expect(#fixture.commits).toBe(1)
		fixture.resources:_dispatchChanges()
		expect(order).toEqual({ "Added:Resource.Rage", "19" })
	end
)

it(
	"filters regeneration before observation while retaining final authority and meaningful classification in a batch",
	function()
		local all: { { ResourceTypes.ResourceMutation } } = {}
		local meaningful: { { ResourceTypes.ResourceMutation } } = {}

		local observer: ResourceTypes.ResourceMutationObserver = {
			includeRegenSteps = false,
			Commit = function(mutations: { ResourceTypes.ResourceMutation })
				table.insert(meaningful, mutations)
			end,
			Dispatch = function() end,
		}

		local stale = fixture.resources:_observeMutations(observer)
		local disconnect = fixture.resources:_observeMutations(observer)
		stale()
		fixture.resources:Step(0.1)
		expect(meaningful).toEqual({})

		local disconnectAll = fixture.resources:_observeMutations({
			Commit = function(mutations: { ResourceTypes.ResourceMutation })
				table.insert(all, mutations)
			end,
			Dispatch = function() end,
		})

		fixture.resources:_beginMutationBatch()
		fixture.resources:Step(0.1)
		fixture.resources:Spend("Resource.Mana", 5)
		fixture.resources:Step(0.1)
		fixture.resources:_finishMutationBatch()
		fixture.resources:_dispatchChanges()
		expect(meaningful).toEqual({ { { resourceId = "Resource.Mana", kind = "Discrete" } } })

		expect(all).toEqual({
			{
				{ resourceId = "Private.Secret", kind = "RegenStep" },
				{ resourceId = "Resource.Mana", kind = "Discrete" },
				{ resourceId = "Resource.Stamina", kind = "RegenStep" },
			},
		})

		expect(fixture.resources:GetCurrent("Resource.Mana")).toBe(38)
		disconnectAll()
		disconnectAll()
		disconnect()
		fixture.resources:Step(0.1)
		expect(#meaningful).toBe(1)
		expect(#all).toBe(1)
	end
)

it("does not let a stale observer disconnect remove its replacement registration", function()
	local commits: number = 0

	local observer: ResourceTypes.ResourceMutationObserver = {
		Commit = function()
			commits += 1
		end,
		Dispatch = function() end,
	}

	local stale = fixture.resources:_observeMutations(observer)
	local disconnect = fixture.resources:_observeMutations(observer)
	stale()
	fixture.resources:Step(0.1)
	expect(commits).toBe(3)
	disconnect()
	disconnect()
	fixture.resources:Step(0.1)
	expect(commits).toBe(3)
end)

it("does not resurrect a destroyed controller through assignment", function()
	fixture.resources:Destroy()
	local success: boolean, reason: string? = fixture.resources:AddResource("Resource.Mana")
	expect(success).toBe(false)
	expect(reason).toBe("ResourceControllerDestroyed")
	expect(fixture.resources:GetCurrent("Resource.Mana")).toBeNil()
	fixture.resources:Step(1)
	expect(fixture.resources:HasResource("Resource.Mana")).toBe(false)
end)
