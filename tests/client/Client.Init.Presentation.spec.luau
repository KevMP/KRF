--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local ClientTypes = require(KRF.client.types)
local Client: ClientTypes.Client = require(KRF.client)
local Events = require(KRF.client.Presentation.PresentationEvents)
local Types = require(KRF.client.Presentation.types)
local Registry = require(KRF.client.Actor.utils.ActorViewRegistryState)
local States = require(KRF.client.Presentation.PresentationStates)
local PresentationRegistry = require(KRF.client.Presentation.PresentationRegistry)
local PresentationRuntime = require(KRF.client.Presentation.PresentationRuntime)
local HintState = require(KRF.client.Networking.utils.HintRuntimeState)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local NetworkingTypes = require(KRF.client.Networking.types)
local ClientUtils = require(script.Parent.Utils.ClientTestUtils)
local StateUtils = require(script.Parent.Utils.PresentationStateTestUtils)

local disconnects: { () -> () } = {}

afterEach(function()
	for _, disconnect in disconnects do
		disconnect()
	end

	table.clear(disconnects)
	Client._ResetForTests()
	StateUtils.reset()
end)

it("rejects a malformed catalog before it listens for bootstrap", function()
	for _, catalog: any in { false, { [2] = {} }, { named = {} }, { false } } do
		Client._ResetForTests()
		local fixture: ClientUtils.Fixture = ClientUtils.new()
		ClientUtils.start(fixture, { presentations = catalog })

		expect(fixture.result).toEqual({
			success = false,
			failure = {
				system = "Presentation",
				reason = if catalog == false or catalog[1] == nil
					then "PresentationCatalogInvalid"
					else "PresentationDefinitionInvalid",
			},
		})

		expect(fixture.order).toEqual({})
	end
end)

it("accepts an empty catalog and retains single-attempt startup", function()
	local fixture: ClientUtils.Fixture = ClientUtils.new()
	ClientUtils.start(fixture, { presentations = {} })
	ClientUtils.bootstrap(fixture)
	ClientUtils.acknowledge(fixture)
	expect(fixture.result).toEqual({ success = true })
	local success: boolean, failure: ClientTypes.StartupFailure? = Client.Init({ presentations = {} })
	expect(success).toBe(false)
	expect(failure).toEqual({ system = "Client", reason = "ClientInitAlreadyAttempted" })
end)

it("rejects a fabricated event descriptor even when its fields match a real descriptor", function()
	local fixture: ClientUtils.Fixture = ClientUtils.new()

	ClientUtils.start(fixture, {
		presentations = {
			{
				id = "Spark",
				entry = { id = "Impact", event = { source = "Hint", event = "Received" } },
				create = function() end,
			},
		},
	})

	expect(fixture.result).toEqual({
		success = false,
		failure = { system = "Presentation", reason = "PresentationEntryEventInvalid" },
	})

	expect(fixture.order).toEqual({})
end)

it("rejects an invalid definition without activating a valid sibling", function()
	local calls: number = 0

	local valid: Types.PresentationDefinition = {
		id = "Valid",
		entry = { id = "Impact", event = Events.Hint.Received },
		create = function()
			calls += 1
		end,
	}

	local cases: { { definition: any, reason: string } } = {
		{ definition = valid, reason = "PresentationIdDuplicate" },
		{ definition = { id = "", create = valid.create }, reason = "PresentationIdInvalid" },
		{ definition = { id = "Other", entry = valid.entry }, reason = "PresentationCreateInvalid" },
		{ definition = { id = "Other", entry = false, create = valid.create }, reason = "PresentationEntryInvalid" },
		{
			definition = { id = "Other", entry = valid.entry, create = valid.create, extra = true },
			reason = "PresentationDefinitionFieldUnknown",
		},
		{
			definition = { id = "Other", entry = { event = Events.Hint.Received, id = "" }, create = valid.create },
			reason = "PresentationEntryIdInvalid",
		},
		{
			definition = {
				id = "Other",
				entry = { event = Events.Hint.Received, id = "Impact", wildcard = true },
				create = valid.create,
			},
			reason = "PresentationEntryFieldUnknown",
		},
	}

	for _, case in cases do
		Client._ResetForTests()
		local fixture: ClientUtils.Fixture = ClientUtils.new()
		ClientUtils.start(fixture, { presentations = { valid, case.definition } })
		expect(fixture.result).toEqual({ success = false, failure = { system = "Presentation", reason = case.reason } })
		expect(fixture.order).toEqual({})
		HintState.Notify({ hintId = "Impact" })
	end

	task.wait()
	expect(calls).toBe(0)
end)

it("does not publish valid definitions during bootstrap or after handshake failure", function()
	local fixture: ClientUtils.Fixture = ClientUtils.new()
	local calls: number = 0

	ClientUtils.start(fixture, {
		presentations = {
			{
				id = "Valid",
				entry = { id = "Impact", event = Events.Hint.Received },
				create = function()
					calls += 1
				end,
			},
		},
	})

	ClientUtils.bootstrap(fixture)
	expect(fixture.result).toBeNil()
	HintState.Notify({ hintId = "Impact" })
	assert(fixture.timeoutCallback ~= nil, "Expected scheduled startup timeout")
	fixture.timeoutCallback()
	ClientUtils.expectFailure(fixture, "HandshakeTimeout")
	HintState.Notify({ hintId = "Impact" })
	task.wait()
	expect(calls).toBe(0)
end)

it("rolls back the client and releases the installer when source attachment fails", function()
	local fixture: ClientUtils.Fixture = ClientUtils.new()

	ClientUtils.start(fixture, {
		presentations = {
			{ id = "World", entry = { event = Events.Hint.Received, id = "Impact" }, create = function() end },
		},
	})

	ClientUtils.bootstrap(fixture)

	-- Core consumers already own their slots by the time Presentation attaches.
	for _ = 1, 64 do
		local added: boolean, disconnect: any = pcall(Registry.ObserveInvalidation, function() end)

		if not added then
			break
		end

		table.insert(disconnects, disconnect)
	end

	ClientUtils.acknowledge(fixture)

	expect(fixture.result).toEqual({
		success = false,
		failure = { system = "Presentation", reason = "PresentationInstallationFailed" },
	})

	expect(fixture.consumerCleanupCalls).toBe(1)
	expect(Client._IsInitialized()).toBe(false)

	-- The failed installation must not retain a singleton or its partial observer.
	local stop, reason = PresentationRuntime.Install(assert(PresentationRegistry.Prepare({})))
	expect(reason).toBeNil()
	assert(stop ~= nil, "Presentation installer remained claimed after rollback")
	stop()
	stop()
end)

it("refuses a second framework installation while the client owns Presentation", function()
	local fixture: ClientUtils.Fixture = ClientUtils.new()
	ClientUtils.start(fixture, { presentations = {} })
	ClientUtils.bootstrap(fixture)
	ClientUtils.acknowledge(fixture)

	local stop, reason = PresentationRuntime.Install(assert(PresentationRegistry.Prepare({})))
	expect(stop).toBeNil()
	expect(reason).toBe("PresentationAlreadyInstalled")
end)

it("passes the consumer installation's private readiness source to Presentation and releases it on reset", function()
	local actor: StateUtils.Actor = StateUtils.actor("Burner", { Burning = { stackCount = 1 } })

	local readiness: StateUtils.Readiness = StateUtils.readiness()
	readiness.ready[actor.view] = true

	local fixture: ClientUtils.Fixture = ClientUtils.new()
	local contexts: { Types.PresentationContext } = {}

	fixture.dependencies.InstallConsumers = function(
		_protocol: SharedNetworkingTypes.ClientProtocol,
		_manifest: SharedNetworkingTypes.ProtocolManifest?,
		_installActorReceiver: (((any) -> ()) -> ())?,
		_sendReliable: ((buffer) -> ())?,
		_isReady: (() -> boolean)?,
		_onTerminalFailure: (() -> ())?,
		_sendUnreliable: ((buffer) -> ())?,
		_connectUnreliable: NetworkingTypes.ClientUnreliableObserver?,
		installReadiness: ((NetworkingTypes.ActorViewStateReadinessSource) -> ())?
	): (boolean, string?, (() -> ())?)
		assert(installReadiness, "Expected a private readiness installer")(readiness.source)

		return true, nil, function() end
	end

	ClientUtils.start(fixture, {
		presentations = {
			{
				id = "Aura",
				entry = { state = States.Tag.Active, id = "Burning" },
				create = function(context: Types.PresentationContext)
					table.insert(contexts, context)
				end,
			},
		},
	})

	ClientUtils.bootstrap(fixture)
	task.wait()
	expect(#contexts).toBe(0)
	expect((next(readiness.observers))).toBeNil()
	ClientUtils.acknowledge(fixture)
	expect(fixture.result).toEqual({ success = true })
	task.wait()
	expect(#contexts).toBe(1)
	expect((next(readiness.observers))).never.toBeNil()
	Client._ResetForTests()
	expect(contexts[1]:IsActive()).toBe(false)
	expect((next(readiness.observers))).toBeNil()
end)
