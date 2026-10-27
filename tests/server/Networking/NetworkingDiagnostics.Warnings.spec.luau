--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Metrics = require(KRF.shared.Networking.utils.NetworkingMetrics)
local State = require(KRF.server.Networking.utils.NetworkingDiagnosticsState)
local ClientState = require(KRF.client.Networking.utils.NetworkingDiagnosticsState)
local SharedTypes = require(KRF.shared.Networking.types)
local Commands = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)
local Resync = require(script.Parent.Parent.Utils.Networking.ResyncTestUtils)
local Protocol = require(script.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)
local Warnings = require(KRF.shared.Networking.utils.NetworkingWarnings)
local Receiver = require(KRF.client.Networking.utils.HintReceiver)
local Manifest = require(KRF.shared.Networking.ManifestCompiler)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local HintConstants = require(KRF.shared.Networking.utils.HintConstants)
local Streams = require(script.Parent.Parent.Parent.client.Utils.ActorStreamTestUtils)
local Views = require(KRF.client.Networking.ActorViewRuntime)
local ClientTypes = require(KRF.client.Networking.types)
local Awareness = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local warningEnvironment = getfenv(Warnings.Emit)
local command: Commands.Fixture?
local resync: Resync.Fixture?
local awareness: Awareness.Fixture?

afterEach(function()
	setfenv(Warnings.Emit, warningEnvironment)
	Commands.destroy(command)

	if resync ~= nil then
		Resync.destroy(resync)
	end

	command, resync = nil, nil

	if awareness ~= nil then
		Awareness.destroy(awareness)
		awareness = nil
	end

	State.Stop()
	ClientState.Stop(nil)
end)

it("retains the first category warning, bounds changing reasons, and summarizes at the next window", function()
	local now = 0
	local output: { { category: string, reason: string?, suppressed: number } } = {}

	local owner = Metrics.new("Server", nil, {
		Now = function(): number
			return now
		end,
		windowSeconds = 5,
		maxPerWindow = 1,
		Emit = function(category: SharedTypes.DiagnosticWarning, reason: string?, suppressed: number)
			table.insert(output, { category = category, reason = reason, suppressed = suppressed })
		end,
	})

	owner:Warn("MalformedTraffic", "First")

	for index = 1, 100 do
		owner:Count("commandsRefused", 1)
		owner:Warn("MalformedTraffic", tostring(index))
	end

	owner:Warn("ResyncAbuse", "Independent")
	expect(#output).toBe(2)
	expect(output[1].reason).toBe("First")
	expect(output[1].suppressed).toBe(0)
	expect(owner:Snapshot().counters.commandsRefused).toBe(100)
	now = 4.999
	owner:Warn("MalformedTraffic", "StillSuppressed")
	expect(#output).toBe(2)
	now = 5
	owner:Warn("MalformedTraffic", "Next")
	expect(#output).toBe(3)
	expect(output[3].reason).toBe("Next")
	expect(output[3].suppressed).toBe(101)
	now = 10
	owner:Warn("MalformedTraffic", "Fresh")
	expect(output[4].suppressed).toBe(0)
end)

it("shares the server bound across connection churn and disables detached owners without losing counters", function()
	local logs = 0

	State.Start({
		Emit = function()
			logs += 1
		end,
	})

	local player = Protocol.createPlayer()
	local first = assert(State.GetConnection(player))
	first:Warn("CommandOverload", nil)
	State.Close(player)
	first:Warn("HintAbuse", nil)
	first:Count("commandsRefused", 1)
	local second = assert(State.GetConnection(player))
	second:Warn("CommandOverload", nil)
	expect(logs).toBe(1)
	expect(assert(State.GetServer()):Snapshot().counters.commandsRefused).toBe(1)
	State.Stop()
	second:Warn("ResyncAbuse", nil)
	expect(logs).toBe(1)

	State.Start({
		Emit = function()
			logs += 1
		end,
	})

	local restarted: SharedTypes.DiagnosticCollector = assert(State.GetServer())
	restarted:Warn("CommandOverload", nil)
	expect(logs).toBe(2)
	player:Destroy()
end)

it("rejects invalid logging bounds and honors a configurable burst without retaining reasons", function()
	for _, seconds in { 0, -1, math.huge, 0 / 0 } do
		expect(function()
			Warnings.new({ windowSeconds = seconds })
		end).toThrow("InvalidWarningWindow")
	end

	for _, maximum in { 0, -1, 1.5, math.huge, 0 / 0 } do
		expect(function()
			Warnings.new({ maxPerWindow = maximum })
		end).toThrow("InvalidWarningLimit")
	end

	local now = 0

	local gate = Warnings.new({
		Now = function(): number
			return now
		end,
		windowSeconds = 2,
		maxPerWindow = 2,
	})

	expect((gate.Allow("TransportFault"))).toBe(true)
	expect((gate.Allow("TransportFault"))).toBe(true)
	expect((gate.Allow("TransportFault"))).toBe(false)
	now = 2
	local allowed, suppressed = gate.Allow("TransportFault")
	expect(allowed).toBe(true)
	expect(suppressed).toBe(1)
	gate.Destroy()
	gate.Destroy()
	expect((gate.Allow("ObserverFault"))).toBe(false)
end)

it("contains throwing or yielding log sinks and leaves all outcome counters intact", function()
	local calls = 0

	local first = Metrics.new("Server", nil, {
		Emit = function()
			calls += 1
			error("BrokenLogger")
		end,
	})

	first:Warn("MalformedTraffic", nil)
	first:Warn("MalformedTraffic", nil)
	first:Count("commandsRefused", 7)
	expect(calls).toBe(1)
	expect(first:Snapshot().counters.commandsRefused).toBe(7)
	local resumed = false

	local second = Metrics.new("Client", nil, {
		Emit = function()
			coroutine.yield()
			resumed = true
		end,
	})

	second:Warn("HintAbuse", nil)
	second:Count("hintPacketsRefused", 9)
	expect(second:Snapshot().counters.hintPacketsRefused).toBe(9)
	expect(resumed).toBe(false)
end)

it("isolates replacement client lifetimes and commits suppression before reentrant logging", function()
	local logs = 0
	local first: SharedTypes.DiagnosticCollector?

	first = ClientState.Start({
		Emit = function()
			logs += 1
			local reentrant: SharedTypes.DiagnosticCollector = assert(first, "Expected installed client diagnostics")
			reentrant:Warn("HintAbuse", nil)
		end,
	})

	local original: SharedTypes.DiagnosticCollector = assert(first, "Expected installed client diagnostics")
	original:Warn("HintAbuse", nil)
	expect(logs).toBe(1)

	local second = ClientState.Start({
		Emit = function()
			logs += 1
		end,
	})

	original:Warn("MalformedTraffic", nil)
	ClientState.Stop(first)
	second:Warn("HintAbuse", nil)
	expect(logs).toBe(2)
	ClientState.Stop(second)
	second:Warn("CommandFault", nil)
	expect(logs).toBe(2)
end)

it("formats only admitted output and reports suppressed repetitions without an idle timer", function()
	local now = 0
	local output: { string } = {}

	setfenv(
		Warnings.Emit,
		setmetatable({
			warn = function(message: string)
				table.insert(output, message)
			end,
		}, { __index = warningEnvironment })
	)

	local owner = Metrics.new("Client", nil, {
		Now = function(): number
			return now
		end,
	})

	owner:Warn("HintAbuse", nil)
	owner:Warn("HintAbuse", "Hidden")
	expect(output).toEqual({ "[Networking] HintAbuse" })
	now = 100
	expect(#output).toBe(1)
	owner:Warn("HintAbuse", "New")
	expect(output[2]).toBe("[Networking] HintAbuse: New (suppressed 1 repeats)")
end)

it("retains exact malformed Hint and rate refusal counts with only two category warnings", function()
	local logs = 0

	local owner = ClientState.Start({
		Emit = function()
			logs += 1
		end,
	})

	local stream = Streams.new()

	local limits: ClientTypes.HintReceiveLimits = table.clone(HintConstants.RECEIVE) :: ClientTypes.HintReceiveLimits
	limits.maxPackets = 3

	local runtime = Receiver.new(
		assert(Manifest.Reconstruct({ version = Constants.PROTOCOL_VERSION, domains = {} })),
		Streams.start(stream),
		{
			Now = function(): number
				return 0
			end,
			IsReady = function(): boolean
				return true
			end,
			Notify = function()
				error("Malformed Hint reached consumer")
			end,
		},
		limits
	)

	for index = 1, 20 do
		local ok, reason = runtime:Handle("malformed")
		expect(ok).toBe(false)
		expect(reason).toBe(if index <= 3 then "MalformedHintPacket" else "HintRateLimited")
	end

	expect(logs).toBe(2)
	local snapshot = owner:Snapshot()
	expect(snapshot.counters.hintsMalformed).toBe(3)
	expect(snapshot.counters.hintPacketsRefused).toBe(20)
	expect(snapshot.counters.hintPacketsDropped).toBe(20)
	expect(snapshot.counters.hintsReceived).toBe(0)
	runtime:Destroy()
	Streams.destroy(stream)
end)

it("marks terminal Actor faults separately from repeated recoverable reports", function()
	local terminal: { boolean } = {}

	local runtime = Views.new(
		assert(Manifest.Reconstruct({ version = Constants.PROTOCOL_VERSION, domains = {} })),
		{},
		{
			Now = function(): number
				return 0
			end,
			ScheduleTimeout = function()
				return function() end
			end,
			SendReliable = function() end,
			ReportFault = function(_fault: ClientTypes.ActorViewFault, isTerminal: boolean?)
				table.insert(terminal, isTerminal == true)
			end,
		}
	)

	local actor: ClientTypes.ActorStreamRecord = { actorId = "WarningTest", handle = 1, model = nil }
	runtime.consumer.OnBaselineReady(actor, -1, {})
	runtime.consumer.OnActorHalted(actor)
	runtime.consumer.OnActorHalted(actor)
	expect(terminal).toEqual({ false, true })
	runtime:Destroy()
end)

it("keeps overload and malformed ingress outcomes exact while bounding output", function()
	local logs: { string } = {}

	State.Start({
		Emit = function(category: SharedTypes.DiagnosticWarning)
			table.insert(logs, category)
		end,
	})

	local created = Commands.new({ Commands.definition("Test") }, { maxRequests = 3 })
	command = created

	for index = 1, 6 do
		local ok, reason = created.runtime:Handle(created.player, "malformed")
		expect(ok).toBe(false)
		expect(reason).toBe(if index <= 3 then "MalformedCommandEnvelope" else "CommandRateLimited")
	end

	local snapshot = assert(State.GetConnection(created.player)):Snapshot()
	expect(snapshot.counters.commandsReceived).toBe(6)
	expect(snapshot.counters.commandsRefused).toBe(6)
	expect(snapshot.counters.commandsRateLimited).toBe(3)
	expect(snapshot.counters.commandsExecuted).toBe(0)
	expect(#logs).toBe(2)
	expect(logs[1]).toBe("MalformedTraffic")
	expect(logs[2]).toBe("CommandOverload")
end)

it("bounds resync abuse independently of refusals and preserves its rate-window recovery", function()
	local logs = 0

	State.Start({
		Emit = function()
			logs += 1
		end,
	})

	local created = Resync.new()
	resync = created
	local player = Resync.player(created)

	for index = 1, 10 do
		local ok, reason = Resync.request(created, player, 99)
		expect(ok).toBe(false)
		expect(reason).toBe(if index <= 4 then "UnknownActorHandle" else "ResyncRateLimited")
	end

	expect(logs).toBe(1)
	created.now += 10
	local _, reason = Resync.request(created, player, 99)
	expect(reason).toBe("UnknownActorHandle")
	local snapshot = assert(State.GetServer()):Snapshot()
	expect(snapshot.counters.resyncRequests).toBe(11)
	expect(snapshot.counters.resyncRefused).toBe(11)
	expect(snapshot.counters.resyncRateLimited).toBe(6)
end)

it("releases recovery ownership when a warning sink closes the connection during capture refusal", function()
	local fixture = Awareness.new()
	awareness = fixture
	fixture.options.backlogLimits = { maxBytes = 1 }

	local player = Awareness.player(fixture)
	Awareness.actor(fixture, nil)
	Awareness.start(fixture)
	local logs = 0

	State.Start({
		Emit = function(category: SharedTypes.DiagnosticWarning)
			if category == "BaselineRecovery" then
				logs += 1
				Awareness.close(fixture, player)
				State.Close(player)
			end
		end,
	})

	Awareness.ready(fixture, player)
	local owner = assert(State.GetServer(), "Expected server diagnostics")
	local snapshot = owner:Snapshot()
	expect(logs).toBe(1)
	expect(snapshot.counters.recoveryBackoffs).toBe(1)
	expect(snapshot.counters.recoveryAbandoned).toBe(1)
	expect(snapshot.gauges.recoveryStreams.current).toBe(0)
	expect(snapshot.gauges.baselineGenerations.current).toBe(0)
	expect(snapshot.gauges.reliableRecords.current).toBe(0)
	expect(State.FindConnection(player)).toBeNil()
end)
