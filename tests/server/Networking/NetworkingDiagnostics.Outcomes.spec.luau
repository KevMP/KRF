--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Metrics = require(KRF.shared.Networking.utils.NetworkingMetrics)
local State = require(KRF.server.Networking.utils.NetworkingDiagnosticsState)
local Diagnostics = require(KRF.server.Networking.NetworkingDiagnostics)
local Constants = require(KRF.shared.Networking.utils.CommandConstants)
local Commands = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)
local Awareness = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local Resync = require(script.Parent.Parent.Utils.Networking.ResyncTestUtils)
local command: Commands.Fixture?
local resync: Resync.Fixture?

beforeEach(function()
	State.Start()
end)

afterEach(function()
	Commands.destroy(command)

	if resync ~= nil then
		Resync.destroy(resync)
	end

	command, resync = nil, nil
	State.Stop()
end)

it("keeps maxima independent of additive ownership and samples current ages only when requested", function()
	local root: SharedTypes.DiagnosticCollector = Metrics.new("Server", nil)
	local first = Metrics.new("Connection", root)
	local second = Metrics.new("Connection", root)
	first:Observe("commandQueueResidenceSeconds", 4)
	second:Observe("commandQueueResidenceSeconds", 7)
	first:Observe("commandQueueResidenceSeconds", 2)
	expect(root:Snapshot().maxima.commandQueueResidenceSeconds).toBe(7)
	expect(first:Snapshot().maxima.commandQueueResidenceSeconds).toBe(4)
	first:Adjust("commandResultSlots", 2)
	second:Adjust("commandResultSlots", 3)
	expect(first:Set("commandResultSlots", 0)).toBe(2)
	expect(root:GetCurrent("commandResultSlots")).toBe(3)
	expect(root:Snapshot().gauges.commandResultSlots.highWater).toBe(5)
	local reads = 0

	first:SetAgeSource("commandQueueAgeSeconds", function(): number
		reads += 1

		return 9
	end)

	expect(reads).toBe(0)
	local snapshot = first:Snapshot()
	expect(snapshot.ages.commandQueueAgeSeconds).toBe(9)
	expect(reads).toBe(1)
	expect(table.isfrozen(snapshot.ages)).toBe(true)
	expect(table.isfrozen(snapshot.maxima)).toBe(true)
	first:ClearSources()
	expect(first:GetAge("commandQueueAgeSeconds")).toBeNil()
	expect(snapshot.ages.commandQueueAgeSeconds).toBe(9)
end)

it("distinguishes received admission, dispatch, author execution, definitive outcomes and uncertainty", function()
	local accepted = Commands.definition("A.Accept")

	local denied = Commands.definition("B.Deny")

	denied.authorize = function(): (boolean, string?)
		return false, "Denied"
	end

	local rejected = Commands.definition("C.Reject")

	rejected.handle = function(): Types.CommandHandlerResult
		return { accepted = false, reason = "Rejected" }
	end

	local faulted = Commands.definition("D.Fault")

	faulted.handle = function(): Types.CommandHandlerResult
		error("AfterEffect")
	end

	local created = Commands.new({ accepted, denied, rejected, faulted }, { maxRequests = 4, maxDispatchRequests = 1 })
	command = created
	local ids = { "A.Accept", "B.Deny", "C.Reject", "D.Fault" }

	for index, id in ids do
		expect((created.runtime:Handle(created.player, Commands.request(created, index, id, nil, nil, nil)))).toBe(true)
	end

	local pending = assert(Diagnostics.GetConnectionSnapshot(created.player))
	expect(pending.counters.commandsReceived).toBe(4)
	expect(pending.counters.commandsAdmitted).toBe(4)
	expect(pending.counters.commandsExecuted).toBe(0)
	created.now = 100.5
	expect(assert(Diagnostics.GetConnectionSnapshot(created.player)).ages.commandQueueAgeSeconds).toBe(0.5)

	for _ = 1, 4 do
		created.runtime:Step()
	end

	local completed = assert(Diagnostics.GetConnectionSnapshot(created.player))
	expect(completed.counters.commandsDispatched).toBe(4)
	expect(completed.counters.commandsExecuted).toBe(3)
	expect(completed.counters.commandsAccepted).toBe(1)
	expect(completed.counters.commandsRejected).toBe(2)
	expect(completed.counters.commandsFaulted).toBe(1)
	expect(completed.counters.commandsUncertain).toBe(1)
	expect(completed.maxima.commandQueueResidenceSeconds).toBe(0.5)
	expect(completed.gauges.commandResultSlots.current).toBe(4)
	expect(completed.gauges.commandResultReservedBytes.current).toBe(4 * (9 + Constants.MAX_REASON_BYTES))
	expect(completed.gauges.commandHistoryEntries.current).toBe(4)

	local admitted, reason =
		created.runtime:Handle(created.player, Commands.request(created, 5, "A.Accept", nil, nil, nil))

	expect(admitted).toBe(false)
	expect(reason).toBe("CommandRateLimited")
	expect(assert(Diagnostics.GetServerSnapshot()).counters.commandsReceived).toBe(5)
	expect(assert(Diagnostics.GetServerSnapshot()).counters.commandsRateLimited).toBe(1)
	Commands.results(created)
	local drained = assert(Diagnostics.GetConnectionSnapshot(created.player))
	expect(drained.gauges.commandResultSlots.current).toBe(0)
	expect(drained.gauges.commandResultReservedBytes.current).toBe(0)
	expect(drained.gauges.commandResultSlots.highWater).toBe(4)
	Awareness.close(created.base, created.player)
	expect(assert(Diagnostics.GetServerSnapshot()).gauges.commandHistoryEntries.current).toBe(0)
end)

it("counts resync deduplication separately from abuse refusal and clears current age providers on close", function()
	local created = Resync.new()
	resync = created
	local player = Resync.player(created)
	local collector = assert(State.GetConnection(player))
	expect((Resync.request(created, player, 1))).toBe(true)
	local accepted, reason = Resync.request(created, player, 1)
	expect(accepted).toBe(false)
	expect(reason).toBe("BaselineAlreadyPending")
	accepted, reason = Resync.request(created, player, 99)
	expect(accepted).toBe(false)
	expect(reason).toBe("UnknownActorHandle")
	expect((Resync.request(created, player, 2))).toBe(true)
	accepted, reason = Resync.request(created, player, 3)
	expect(accepted).toBe(false)
	expect(reason).toBe("ResyncRateLimited")
	local snapshot = assert(Diagnostics.GetConnectionSnapshot(player))
	expect(snapshot.counters.resyncRequests).toBe(5)
	expect(snapshot.counters.resyncAdmitted).toBe(2)
	expect(snapshot.counters.resyncDeduplicated).toBe(1)
	expect(snapshot.counters.resyncRateLimited).toBe(1)
	expect(snapshot.counters.resyncRefused).toBe(3)

	collector:SetAgeSource("commandQueueAgeSeconds", function(): number
		return 5
	end)

	State.Close(player)
	expect(collector:GetAge("commandQueueAgeSeconds")).toBeNil()
	expect(Diagnostics.GetConnectionSnapshot(player)).toBeNil()
	expect(assert(Diagnostics.GetServerSnapshot()).counters.resyncRequests).toBe(5)
end)

it(
	"keeps an executing old connection's metrics separate from re-Ready work and excludes an unfilled result from eligible age",
	function()
		local created: Commands.Fixture? = nil
		local previous: SharedTypes.DiagnosticCollector? = nil
		local callbackEntered = false
		local reservationAge: number? = nil

		local definition = Commands.definition("Game.Command")

		definition.handle = function(context: Types.CommandContext): Types.CommandHandlerResult
			if context.requestId == 1 then
				local active = assert(created, "Expected bound command fixture")
				previous = State.FindConnection(active.player)

				reservationAge =
					assert(Diagnostics.GetConnectionSnapshot(active.player)).ages.reliableEligibleQueueAgeSeconds

				State.Close(active.player)
				Awareness.close(active.base, active.player)
				Awareness.ready(active.base, active.player)
				active.runtime:Handle(active.player, Commands.request(active, 2, nil, nil, nil, nil))
				callbackEntered = true
			end

			return { accepted = true }
		end

		local active = Commands.new({ definition }, { maxDispatchRequests = 1 })
		created, command = active, active
		expect((active.runtime:Handle(active.player, Commands.request(active, 1, nil, nil, nil, nil)))).toBe(true)
		active.runtime:Step()
		expect(callbackEntered).toBe(true)
		expect(reservationAge).toBeNil()
		local old = assert(previous, "Expected prior connection collector")
		local current = assert(State.FindConnection(active.player))
		expect(old:Snapshot().counters.commandsUncertain).toBe(1)
		expect(old:Snapshot().counters.commandsAccepted).toBe(0)
		expect(old:Snapshot().gauges.commandRequests.current).toBe(0)
		expect(old:Snapshot().gauges.commandResultSlots.current).toBe(0)
		expect(current:Snapshot().counters.commandsUncertain).toBe(0)
		expect(current:Snapshot().gauges.commandRequests.current).toBe(1)
		expect(assert(Diagnostics.GetServerSnapshot()).gauges.commandRequests.current).toBe(1)
		active.runtime:Step()
		expect(current:Snapshot().counters.commandsAccepted).toBe(1)
		expect(old:Snapshot().counters.commandsAccepted).toBe(0)
		expect(assert(Diagnostics.GetServerSnapshot()).gauges.commandRequests.current).toBe(0)
	end
)

it("counts one faulted and uncertain dispatch when a handler fault is followed by an internal decode fault", function()
	local effects = 0

	local definition = Commands.definition("Game.Command")

	definition.handle = function(): Types.CommandHandlerResult
		effects += 1
		error("AfterEffect")
	end

	local created = Commands.new({ definition })
	command = created

	-- Deliberately fail the private codec after the real handler fault, so both
	-- the execution and outer dispatch cleanup paths observe the same request.
	local internal: any = created.runtime
	internal.execution.codec = table.clone(internal.execution.codec)

	internal.execution.codec.DecodeResult = function(): ()
		error("DecodeUnavailable")
	end

	expect((created.runtime:Handle(created.player, Commands.request(created, 1, nil, nil, nil, nil)))).toBe(true)
	local owner = assert(State.FindConnection(created.player))
	created.runtime:Step()
	expect(effects).toBe(1)
	expect(created.faults).toEqual({ "CommandHandlerFault", "CommandInternalFault" })
	expect(owner:Snapshot().counters.commandsExecuted).toBe(1)
	expect(owner:Snapshot().counters.commandsFaulted).toBe(1)
	expect(owner:Snapshot().counters.commandsUncertain).toBe(1)
	expect(owner:Snapshot().counters.commandsRejected).toBe(0)
	expect(owner:Snapshot().gauges.commandRequests.current).toBe(0)
	expect(owner:Snapshot().gauges.commandResultSlots.current).toBe(0)
end)
