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
local SignalTypes = require(KRF.shared.Signal.types)
local TagController = require(KRF.server.Tags.TagController)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActionsReplicationTestUtils)

local connections: { SignalTypes.Connection } = {}
local disconnect: (() -> ())? = nil

beforeEach(function(): ()
	ActionUtils.reset()
	connections = {}
	disconnect = nil
end)

afterEach(function(): ()
	for _, connection: SignalTypes.Connection in connections do
		connection:Disconnect()
	end

	if disconnect ~= nil then
		disconnect()
	end

	ActionUtils.cleanup()
end)

for _, source: string in { "Tick", "EarlierExpiry" } do
	for _, indefinite: boolean in { false, true } do
		it(
			`preserves a committed reentrant Refresh after {source} observer failure, indefinite={indefinite}`,
			function(): ()
				local original = { reason = "RefreshObserverFailure" }
				local refreshed: boolean? = nil
				local refreshFailure: any = nil
				local shouldRefresh: boolean = true

				local function refresh(actor: ActorTypes.Actor): ()
					if not shouldRefresh then
						return
					end

					shouldRefresh = false
					local tags: TagTypes.TagController = actor:GetController("TagController") :: TagTypes.TagController

					refreshed, refreshFailure = pcall(function(): ()
						tags:AddTag("Capacity", if indefinite then nil else { duration = 5 })
					end)
				end

				ActionUtils.initialize({}, {
					{
						id = "Mana",
						visibility = "ClientVisible",
						autoAssign = true,
						initialValue = 100,
						max = { propertyName = "MaxMana", defaultBaseValue = 100 },
					},
				}, {
					{ id = "Timer", visibility = "ClientVisible", duplicateBehavior = "Ignore" },
					{
						id = "Capacity",
						visibility = "ClientVisible",
						duplicateBehavior = "Refresh",
						properties = { MaxMana = { set = 50 } },
						tickInterval = if source == "Tick" then 1 else nil,
						onTick = if source == "Tick" then refresh else nil,
					},
				})

				local actor: ActorTypes.Actor, _, resources: ResourceTypes.ResourceController, properties: PropertyTypes.PropertyController, publicTags: TagTypes.TagController =
					ActionUtils.registerActor()

				local tags: TagTypes.InternalTagController = publicTags :: TagTypes.InternalTagController

				if source == "EarlierExpiry" then
					expect(tags:AddTag("Timer", { duration = 1 })).toBe(true)
				end

				expect(tags:AddTag("Capacity", { duration = 1 })).toBe(true)
				local expired: { string } = {}
				local refreshedIds: { string } = {}

				table.insert(
					connections,
					tags.OnTagExpired:Connect(function(target: ActorTypes.Actor, id: string): ()
						table.insert(expired, id)

						if id == "Timer" then
							refresh(target)
						end
					end)
				)

				table.insert(
					connections,
					tags.OnTagRefreshed:Connect(function(_actor: ActorTypes.Actor, id: string): ()
						table.insert(refreshedIds, id)
					end)
				)

				disconnect = tags:_observeMutations({
					Commit = function(events: { TagTypes.TagMutationEvent }): ()
						if events[1].kind == "Refreshed" then
							error(original, 0)
						end
					end,
					Dispatch = function(): () end,
				})

				local publication: NetworkingTypes.PublicationRuntime = TestUtils.publication()
				local beforeSequence: number = publication:GetActorSequence(actor)
				local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
				TagController.Step(1)
				expect(refreshed).toBe(false)
				expect(refreshFailure).toBe(original)
				expect(tags:HasTag("Capacity")).toBe(true)
				expect(tags:GetTagInstances("Capacity")[1].remainingDuration).toBe(if indefinite then nil else 5)
				expect(expired).toEqual(if source == "Tick" then {} else { "Timer" })
				expect(refreshedIds).toEqual({ "Capacity" })
				expect(properties:GetResolvedProperty("MaxMana")).toBe(50)
				expect(resources:GetMax("Mana")).toBe(50)
				expect(resources:GetCurrent("Mana")).toBe(50)
				expect(#commits).toBe(if source == "Tick" then 1 else 2)
				expect(publication:GetActorSequence(actor)).toBe(beforeSequence + #commits)
				local latest: NetworkingTypes.PublicationBaseline? = publication:CaptureBaseline(actor)
				assert(latest ~= nil, "Expected current retained publication")
				expect(latest.domains["KRF.Tags"].value.Capacity.stackCount).toBe(1)
				expect(latest.domains["KRF.Tags"].value.Capacity.expiresAt == nil).toBe(indefinite)

				expect(commits[#commits].events).toEqual({
					{ domainId = "KRF.Tags", eventId = "Refreshed", payload = "Capacity" },
				})

				assert(disconnect ~= nil, "Expected private observer registration")
				disconnect()
				table.clear(commits)
				TagController.Step(5)
				expect(tags:HasTag("Capacity")).toBe(indefinite)

				if indefinite then
					expect(#commits).toBe(0)
					expect(tags:RemoveTag("Capacity")).toBe(true)
				end

				expect(#commits).toBe(2)
				expect(properties:GetResolvedProperty("MaxMana")).toBe(100)
				expect(resources:GetMax("Mana")).toBe(100)
				expect(resources:GetCurrent("Mana")).toBe(50)
			end
		)
	end
end
