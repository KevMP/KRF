--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local SharedTypes = require(KRF.shared.Networking.types)
local Schema = require(KRF.shared.Networking.Schema)
local Compiler = require(KRF.shared.Networking.ManifestCompiler)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local Consumers = require(KRF.client.Networking.utils.ClientConsumerInstallation)
local HintInstallation = require(KRF.client.Networking.utils.ClientHintInstallation)
local Commands = require(KRF.client.Networking.CommandRuntime)
local CommandState = require(KRF.client.Networking.utils.CommandRuntimeState)
local Hints = require(KRF.client.Networking.HintRuntime)
local HintState = require(KRF.client.Networking.utils.HintRuntimeState)
local Diagnostics = require(KRF.client.Networking.utils.NetworkingDiagnosticsState)
local StreamUtils = require(script.Parent.Utils.ActorStreamTestUtils)
local Clock = require(script.Parent.Parent.shared.Utils.TestClock)
local cleanup: (() -> ())? = nil
local fixture: StreamUtils.Fixture? = nil

afterEach(function()
	if cleanup ~= nil then
		cleanup()
	end

	cleanup = nil

	if fixture ~= nil then
		StreamUtils.destroy(fixture)
	end

	fixture = nil
	Diagnostics.Stop()
end)

it("keeps commands unavailable when no Ready endpoint was supplied and releases actual consumers", function()
	local manifest: SharedTypes.ProtocolManifest = { version = Constants.PROTOCOL_VERSION, domains = {} }
	local protocol = assert(Compiler.Reconstruct(manifest))
	local clock = Clock.new()
	local installed = false
	local sends = 0

	local accepted, reason, stop = Consumers.Install(protocol, manifest, {
		Now = clock.Now,
		ScheduleTimeout = clock.Schedule,
		installActorReceiver = function(): ()
			installed = true
		end,
		sendReliable = function(): ()
			sends += 1
		end,
	})

	cleanup = stop
	expect(accepted).toBe(true)
	expect(reason).toBeNil()
	expect(installed).toBe(true)
	local id, denial = Commands.Send("Missing", nil, nil)
	expect(id).toBeNil()
	expect(denial).toBe("ClientNotReady")
	expect(sends).toBe(0)
	assert(stop, "Expected consumer cleanup")()
	assert(stop, "Expected consumer cleanup")()
	id, denial = Commands.Send("Missing", nil, nil)
	expect(id).toBeNil()
	expect(denial).toBe("ClientNotReady")
	expect(CommandState.Get()).toBeNil()
	expect(clock.Count()).toBe(0)
end)

it("releases an undriven send-only Hint installation once and revokes retained senders", function()
	local base = StreamUtils.new()
	fixture = base
	local stream = StreamUtils.start(base)

	local manifest: SharedTypes.ProtocolManifest = {
		version = Constants.PROTOCOL_VERSION,
		domains = {},
		hints = {
			{
				id = "Sample",
				code = 0,
				direction = "ClientToServer",
				target = "None",
				mode = "Latest",
				payload = Schema.U8,
			},
		},
	}

	local protocol = assert(Compiler.Reconstruct(manifest))
	local clock = Clock.new()
	local owner = Diagnostics.Start()
	local sends = 0

	local stop = HintInstallation.Install(protocol, stream, {
		Now = clock.Now,
		ScheduleTimeout = clock.Schedule,
		isReady = function(): boolean
			return true
		end,
		sendUnreliable = function(): ()
			sends += 1
		end,
	})

	cleanup = stop
	local retained = assert(HintState.Get())
	expect((Hints.Send("Sample", nil, 1))).toBe(true)
	expect(owner:Snapshot().gauges.hintSendRecords.current).toBe(1)
	stop()
	stop()
	local admitted, denial = retained:Send("Sample", nil, 2)
	expect(admitted).toBe(false)
	expect(denial).toBe("ClientNotReady")
	expect(HintState.Get()).toBeNil()
	expect(owner:Snapshot().gauges.hintSendRecords.current).toBe(0)
	expect(owner:Snapshot().gauges.hintLatestKeys.current).toBe(0)
	expect(sends).toBe(0)
end)
