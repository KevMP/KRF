--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
local ActorEntity = require(KRF.server.Actor.ActorEntity)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActionsReplicationTestUtils)
local PublicationUtils = require(script.Parent.Parent.Utils.Networking.PublicationTestUtils)

local runtime: NetworkingTypes.PublicationRuntime? = nil
beforeEach(ActionUtils.reset)

afterEach(function()
	if runtime ~= nil then
		runtime:Destroy()
		runtime = nil
	end

	ActionUtils.cleanup()
end)

for _, populated: boolean in { false, true } do
	it(
		"captures only current visible sequence membership without history, populated=" .. tostring(populated),
		function()
			TestUtils.initialize({ TestUtils.action("Visible"), TestUtils.action("Private", "ServerOnly") })
			local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
			TestUtils.accept(actions, "Private")

			if populated then
				TestUtils.accept(actions, "Visible", { private = "NeverSerialize", callback = function() end })
				TestUtils.accept(actions, "Visible")
				TestUtils.accept(actions, "Visible")
				expect(actions:EndAction(3)).toBe(true)
			end

			local definition: ReplicationTypes.ReplicationDomainDefinition = TestUtils.build()
			local publication: NetworkingTypes.PublicationRuntime = PublicationUtils.createRuntime({ definition })
			runtime = publication
			local commits: { NetworkingTypes.PublicationCommit } = {}

			publication:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
				table.insert(commits, commit)
			end)

			expect(publication:AttachActor(actor)).toBe(true)

			expect(publication:CaptureBaseline(actor)).toEqual({
				sequence = 0,
				domains = {
					["KRF.Actions"] = { value = if populated then { [2] = "Visible", [4] = "Visible" } else {} },
				},
			})

			expect(commits).toEqual({})
		end
	)
end

it("fails missing ActionController attachment observably without publishing empty state", function()
	TestUtils.initialize({ TestUtils.action("Visible") })
	local publication: NetworkingTypes.PublicationRuntime = PublicationUtils.createRuntime({ TestUtils.build() })
	runtime = publication
	local actor: ActorTypes.Actor = ActorEntity.new()
	local attached: boolean, reason: string? = publication:AttachActor(actor)
	expect(attached).toBe(false)
	expect(reason).toBe("PublicationSnapshotError:KRF.Actions")
	expect(publication:GetAttachedActors()).toEqual({})
	expect(publication:CaptureBaseline(actor)).toBeNil()
end)

for _, invalid: string in { "zero", "negative", "fraction", "overflow", "duplicate", "capacity", "unknown visible id" } do
	it("rejects invalid initial " .. invalid .. " identity atomically and retries against corrected truth", function()
		TestUtils.initialize({ TestUtils.action("Visible") })
		local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()
		local internal: TestUtils.InternalController = TestUtils.internal(actions)
		local originalSnapshot = internal._getActiveReplicationState
		local bad: { TestUtils.Identity } = { { actionId = "Visible", sequenceId = 1 } }

		if invalid == "duplicate" then
			table.insert(bad, { actionId = "Visible", sequenceId = 1 })
		elseif invalid == "capacity" then
			for sequence: number = 2, 257 do
				table.insert(bad, { actionId = "Visible", sequenceId = sequence })
			end
		elseif invalid == "unknown visible id" then
			bad = { { actionId = "NotInCompiledCatalog", sequenceId = 1 } }
		else
			local sequence: number = if invalid == "zero"
				then 0
				elseif invalid == "negative" then -1
				elseif invalid == "fraction" then 1.5
				else 4294967296

			bad = { { actionId = "Visible", sequenceId = sequence } }
		end

		internal._getActiveReplicationState = function(): { TestUtils.Identity }
			return bad :: { TestUtils.Identity }
		end

		local faults: { NetworkingTypes.PublicationFault } = {}

		local publication: NetworkingTypes.PublicationRuntime = PublicationUtils.createRuntime({ TestUtils.build() }, {
			ReportFault = function(fault: NetworkingTypes.PublicationFault)
				table.insert(faults, fault)
			end,
		})

		runtime = publication
		local attached: boolean, reason: string? = publication:AttachActor(actor)
		expect(attached).toBe(false)
		expect(type(reason)).toBe("string")
		expect(#faults).toBe(1)
		expect(faults[1].domainId).toBe("KRF.Actions")
		expect(publication:GetAttachedActors()).toEqual({})
		expect(publication:CaptureBaseline(actor)).toBeNil()
		internal._getActiveReplicationState = originalSnapshot
		expect(publication:AttachActor(actor)).toBe(true)

		expect(publication:CaptureBaseline(actor)).toEqual({
			sequence = 0,
			domains = { ["KRF.Actions"] = { value = {} } },
		})
	end)
end

it(
	"updates a whole mixed batch before one onCommitted and filters private identities before any downstream work",
	function()
		TestUtils.initialize({ TestUtils.action("A"), TestUtils.action("B"), TestUtils.action("Private", "ServerOnly") })
		local actor: ActorTypes.Actor = ActorEntity.new()
		local snapshotReads: number = 0
		local callback: (({ TestUtils.Mutation }) -> ())? = nil
		local disconnected: number = 0

		local controller = {
			Destroy = function() end,
			_getActiveReplicationState = function(): { TestUtils.Identity }
				snapshotReads += 1

				return {
					{ actionId = "A", sequenceId = 1 },
					{ actionId = "Private", sequenceId = 2 },
					{ actionId = "B", sequenceId = 3 },
				}
			end,
			_observeMutations = function(_self: any, observer: ({ TestUtils.Mutation }) -> ()): () -> ()
				callback = observer

				return function()
					disconnected += 1
				end
			end,
		}

		expect(actor:SetController("ActionController", controller)).toBe(true)
		local definition: ReplicationTypes.ReplicationDomainDefinition = TestUtils.build()
		expect(definition.snapshot(actor)).toEqual({ [1] = "A", [3] = "B" })
		local captured: { [number]: string } = definition.snapshot(actor)
		local commits: { any } = {}
		local observe = definition.observe
		assert(observe ~= nil, "N8 must observe committed mutations")

		local disconnect: (() -> ())? = observe(actor, function(events: { ReplicationTypes.ReplicationDomainEvent }?)
			table.insert(commits, { state = definition.snapshot(actor), events = events })
		end)

		assert(callback ~= nil and disconnect ~= nil, "Expected private observer and disconnect")
		local readsAtAttach: number = snapshotReads
		RunService.Heartbeat:Wait()
		RunService.Heartbeat:Wait()
		expect(snapshotReads).toBe(readsAtAttach)
		callback({ { kind = "Started", actionId = "Private", sequenceId = 4 } })
		callback({ { kind = "Ended", actionId = "Private", sequenceId = 4 } })
		callback({ { kind = "Interrupted", actionId = "Private", sequenceId = 2 } })
		expect(commits).toEqual({})

		callback({
			{ kind = "Interrupted", actionId = "A", sequenceId = 1 },
			{ kind = "Started", actionId = "Private", sequenceId = 5 },
			{ kind = "Started", actionId = "B", sequenceId = 6 },
		})

		expect(commits).toEqual({
			{
				state = { [3] = "B", [6] = "B" },
				events = {
					{ id = "Interrupted", payload = { actionId = "A", sequenceId = 1 } },
					{ id = "Started", payload = { actionId = "B", sequenceId = 6 } },
				},
			},
		})

		expect(snapshotReads).toBe(readsAtAttach)
		expect(captured).toEqual({ [1] = "A", [3] = "B" })
		disconnect()
		disconnect()
		expect(disconnected).toBe(1)
		callback({ { kind = "Started", actionId = "A", sequenceId = 7 } })
		expect(#commits).toBe(1)
	end
)
