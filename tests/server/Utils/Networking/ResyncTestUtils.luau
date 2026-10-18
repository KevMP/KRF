--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local Runtime: ServerNetworkingTypes.ResyncRuntimeModule = require(KRF.server.Networking.ResyncRuntime)
local Codec = require(KRF.shared.Networking.utils.ResyncCodec)
local ProtocolUtils = require(script.Parent.Parent.Parent.Parent.shared.Utils.Networking.ProtocolTestUtils)

export type Call = { player: Player, handle: number }
export type Fixture = {
	runtime: ServerNetworkingTypes.ResyncRuntime,
	now: number,
	ready: { [Player]: boolean },
	known: { [Player]: { [number]: boolean } },
	pending: { [Player]: { [number]: boolean } },
	calls: { Call },
	closed: { (Player) -> () },
	players: { Player },
	options: ServerNetworkingTypes.ResyncOptions,
}
local TestUtils = {}

function TestUtils.new(): Fixture
	local fixture: Fixture = {
		runtime = {} :: ServerNetworkingTypes.ResyncRuntime,
		now = 100,
		ready = {},
		known = {},
		pending = {},
		calls = {},
		closed = {},
		players = {},
		options = { windowSeconds = 10, maxRequestsPerClient = 4, maxRequestsPerActor = 2 },
	}
	fixture.runtime = Runtime.new({
		Now = function(): number
			return fixture.now
		end,
		IsClientReady = function(player: Player): boolean
			return fixture.ready[player] == true
		end,
		RequestReplacementBaseline = function(player: Player, handle: number, _reason: string?): (boolean, string?)
			table.insert(fixture.calls, { player = player, handle = handle })
			if fixture.known[player] == nil or fixture.known[player][handle] ~= true then
				return false, "UnknownActorHandle"
			end
			if fixture.pending[player][handle] then
				return false, "BaselineAlreadyPending"
			end
			fixture.pending[player][handle] = true
			return true, nil
		end,
		ObserveClientClosed = function(callback: (Player) -> ()): () -> ()
			table.insert(fixture.closed, callback)
			return function()
				local index: number? = table.find(fixture.closed, callback)
				if index ~= nil then
					table.remove(fixture.closed, index)
				end
			end
		end,
	}, fixture.options)
	return fixture
end

function TestUtils.player(fixture: Fixture): Player
	local player: Player = ProtocolUtils.createPlayer()
	table.insert(fixture.players, player)
	fixture.ready[player] = true
	fixture.known[player] = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true }
	fixture.pending[player] = {}
	return player
end

function TestUtils.request(fixture: Fixture, player: Player, handle: number): (boolean, string?)
	local payload: buffer?, reason: string? = Codec.Encode(handle)
	assert(payload ~= nil, reason)
	return fixture.runtime:Handle(player, payload)
end

function TestUtils.destroy(fixture: Fixture): ()
	fixture.runtime:Destroy()
	for _, player: Player in fixture.players do
		player:Destroy()
	end
end

return TestUtils
