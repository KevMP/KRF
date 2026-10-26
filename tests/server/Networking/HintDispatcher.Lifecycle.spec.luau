--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local Dispatch = require(KRF.server.Networking.utils.HintDispatcher)
local Registry = require(KRF.server.Networking.HintRegistry)
local Authorization = require(KRF.server.Networking.HintAuthorization)
local Networking = require(KRF.server.Networking.ServerNetworking)
local Schema = require(KRF.shared.Networking.Schema)
local Metrics = require(KRF.shared.Networking.utils.NetworkingMetrics)
local Awareness = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: Awareness.Fixture? = nil

afterEach(function()
	if fixture ~= nil then
		Awareness.destroy(fixture)
	end

	fixture = nil
end)

it("revokes old channels and contexts without suppressing or debiting a replacement's first sample", function()
	local base = Awareness.new()
	fixture = base
	local awareness = Awareness.start(base)
	local player = Awareness.player(base)
	local calls = 0
	local escaped: Types.HintContext? = nil

	local catalog = assert(Registry.Prepare({
		{
			id = "Sample",
			direction = "ClientToServer",
			target = "None",
			mode = "Latest",
			payload = Schema.U8,
			authorize = Authorization.AnyReadyClient,
			receive = function(context: Types.HintContext): ()
				calls += 1
				escaped = context
			end,
		},
	}))

	local protocol = assert(Networking.Prepare(base.catalog, nil, catalog))

	local dispatch: Dispatch.Runtime =
		Dispatch.new(catalog, protocol.runtime, awareness, { maxLatestKeys = 1, maxGlobalLatestKeys = 1 })

	local aggregate = Metrics.new("Server")
	local oldOwner = Metrics.new("Connection", aggregate)
	local newOwner = Metrics.new("Connection", aggregate)
	local current = true

	local previous = dispatch:Open(player, oldOwner, function(): boolean
		return current
	end)

	local record: SharedTypes.HintRecord = { hintCode = 0, sequence = 1, payload = 7 }
	expect(dispatch:Deliver(previous, record)).toBe(true)
	expect(calls).toBe(1)
	local retained = assert(escaped, "Expected delivered callback context")
	expect((Authorization.AnyReadyClient(retained, nil))).toBe(false)
	current = false
	dispatch:Close(previous)
	dispatch:Close(previous)
	expect(dispatch:Deliver(previous, record)).toBe(false)

	local replacement = dispatch:Open(player, newOwner, function(): boolean
		return true
	end)

	expect(dispatch:Deliver(replacement, record)).toBe(true)
	dispatch:Close(previous)
	expect(dispatch.keys).toBe(1)
	expect(newOwner:Snapshot().gauges.hintLatestKeys.current).toBe(1)
	expect(dispatch:Deliver(replacement, record)).toBe(false)
	expect(calls).toBe(2)
	expect(aggregate:Snapshot().counters.hintsReceived).toBe(2)
	expect(aggregate:Snapshot().counters.hintsStaleDropped).toBe(1)
	expect(aggregate:Snapshot().counters.hintsDropped).toBe(2)
	dispatch:Close(replacement)
	expect(dispatch.keys).toBe(0)
	expect(aggregate:Snapshot().gauges.hintLatestKeys.current).toBe(0)
end)
