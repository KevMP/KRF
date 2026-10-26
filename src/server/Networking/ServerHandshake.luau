--!strict
local Types = require(script.Parent.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local ProtocolCodec = require(script.Parent.Parent.Parent.shared.Networking.ProtocolCodec)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.ProtocolConstants)
local Warnings = require(script.Parent.Parent.Parent.shared.Networking.utils.NetworkingWarnings)

local ServerHandshake = {} :: Types.ServerHandshakeModule

function ServerHandshake.new(
	protocol: SharedNetworkingTypes.PreparedProtocol,
	dependencies: Types.HandshakeDependencies
): Types.ServerHandshake
	type State = "SendingBootstrap" | "AwaitReady" | "Ready" | "Rejected"
	type Observer = { callback: (Player) -> (), connected: boolean }
	local states: { [Player]: State } = {}
	local closed: { [Player]: boolean } = setmetatable({}, { __mode = "k" })
	local readyObservers: { Observer } = {}
	local closedObservers: { Observer } = {}
	local destroyed: boolean = false
	local warnings = Warnings.new(nil)
	local acknowledgement: buffer?, ackReason: string? = ProtocolCodec.Encode({ kind = "ReadyAck" })
	assert(acknowledgement ~= nil, ackReason)
	local runtime: Types.ServerHandshake = {} :: Types.ServerHandshake

	local function send(player: Player, payload: buffer): boolean
		local completed: boolean, reason: unknown = pcall(dependencies.SendReliable, player, payload)

		if not completed then
			warnings.Report("TransportFault", reason)
		end

		return completed
	end

	local function notify(observers: { Observer }, player: Player, ready: boolean): ()
		for _, observer: Observer in table.clone(observers) do
			if ready and (destroyed or states[player] ~= "Ready") then
				break
			end

			if not observer.connected then
				continue
			end

			local thread: thread = coroutine.create(observer.callback)
			local completed: boolean, reason: unknown = coroutine.resume(thread, player)

			if coroutine.status(thread) ~= "dead" then
				coroutine.close(thread)
				completed = false
				reason = "Yielded"
			end

			if not completed then
				warnings.Report("ObserverFault", reason)
			end
		end
	end

	local function observe(observers: { Observer }, callback: (Player) -> ()): () -> ()
		if destroyed then
			return function(): () end
		end

		local observer: Observer = { callback = callback, connected = true }
		table.insert(observers, observer)

		return function(): ()
			if not observer.connected then
				return
			end

			observer.connected = false

			local index: number? = table.find(observers, observer)

			if index ~= nil then
				table.remove(observers, index)
			end
		end
	end

	function runtime.Handle(_self: Types.ServerHandshake, player: Player, payload: any, ...: any): ()
		if
			destroyed
			or closed[player]
			or select("#", ...) ~= 0
			or typeof(payload) ~= "buffer"
			or buffer.len(payload) > 3
		then
			return
		end

		-- Client-originated bootstrap messages are tiny. Server-only manifest data
		-- never reaches the parser through this callback.
		local message: SharedNetworkingTypes.ProtocolMessage? = ProtocolCodec.Decode(payload)

		if message == nil then
			return
		end

		local state: State? = states[player]

		if message.kind == "Hello" then
			if state ~= nil then
				return
			end

			if message.version ~= Constants.PROTOCOL_VERSION then
				states[player] = "Rejected"

				local rejection: buffer? = ProtocolCodec.Encode({ kind = "Reject", reason = "ProtocolMismatch" })
				assert(rejection ~= nil, "Protocol rejection encoding failed")
				send(player, rejection)

				return
			end

			states[player] = "SendingBootstrap"

			local sent: boolean = send(player, protocol.bootstrapBuffer)

			if not destroyed and not closed[player] then
				states[player] = if sent then "AwaitReady" else "Rejected"
			end
		elseif message.kind == "Ready" and state == "AwaitReady" then
			states[player] = "Ready"

			if send(player, acknowledgement :: buffer) then
				notify(readyObservers, player, true)
			elseif not destroyed and not closed[player] then
				states[player] = "Rejected"
			end
		end
	end

	function runtime.IsClientReady(_self: Types.ServerHandshake, player: Player): boolean
		return not destroyed and states[player] == "Ready"
	end

	function runtime.Send(_self: Types.ServerHandshake, player: Player, payload: buffer): (boolean, string?)
		if not runtime:IsClientReady(player) then
			return false, "ClientNotReady"
		end

		if not send(player, payload) then
			return false, "TransportSendFailed"
		end

		return true, nil
	end

	function runtime.ObserveClientReady(_self: Types.ServerHandshake, callback: (Player) -> ()): () -> ()
		return observe(readyObservers, callback)
	end

	function runtime.ObserveClientClosed(_self: Types.ServerHandshake, callback: (Player) -> ()): () -> ()
		return observe(closedObservers, callback)
	end

	function runtime.Close(_self: Types.ServerHandshake, player: Player): ()
		if closed[player] then
			return
		end

		states[player] = nil
		closed[player] = true
		notify(closedObservers, player, false)
	end

	function runtime.Destroy(_self: Types.ServerHandshake): ()
		if destroyed then
			return
		end

		destroyed = true
		local players: { Player } = {}

		for player: Player in states do
			table.insert(players, player)
		end

		for _, player: Player in players do
			runtime:Close(player)
		end

		table.clear(readyObservers)
		table.clear(closedObservers)
		warnings.Destroy()
	end

	function runtime._GetConnectionCountForTests(_self: Types.ServerHandshake): number
		local count: number = 0

		for _ in states do
			count += 1
		end

		return count
	end

	return runtime
end

return ServerHandshake
