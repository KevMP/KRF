--!strict
local Types = require(script.Parent.types)
local Diagnostics = require(script.Parent.utils.NetworkingDiagnosticsState)
local Metrics = require(script.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Codec = require(script.Parent.Parent.Parent.shared.Networking.utils.ResyncCodec)
type Window = { started: number, attempts: number, actors: { [number]: number } }

local ResyncRuntime = {}

function ResyncRuntime.new(dependencies: Types.ResyncDependencies, options: Types.ResyncOptions): Types.ResyncRuntime
	assert(
		options.windowSeconds > 0 and options.maxRequestsPerClient >= 1 and options.maxRequestsPerActor >= 1,
		"InvalidResyncBounds"
	)

	local diagnostics = Diagnostics.GetServer()
	local windows: { [Player]: Window } = {}
	local destroyed: boolean = false

	local stopClosed: () -> () = dependencies.ObserveClientClosed(function(player: Player)
		windows[player] = nil
	end)

	return {
		Handle = function(_self: Types.ResyncRuntime, player: Player, payload: any, ...: any): (boolean, string?)
			if destroyed then
				return false, "ResyncRuntimeDestroyed"
			end

			local diagnosticOwner = Diagnostics.FindConnection(player) or diagnostics
			Metrics.Count(diagnosticOwner, "resyncRequests", 1)

			if select("#", ...) ~= 0 then
				Metrics.Warn(diagnosticOwner, "MalformedTraffic", "MalformedResyncRequest")
				Metrics.Count(diagnosticOwner, "resyncRefused", 1)

				return false, "MalformedResyncRequest"
			end

			local request: Codec.Request?, reason: string? = Codec.Decode(payload)

			if request == nil then
				Metrics.Warn(diagnosticOwner, "MalformedTraffic", reason)
				Metrics.Count(diagnosticOwner, "resyncRefused", 1)

				return false, reason
			elseif not dependencies.IsClientReady(player) then
				Metrics.Count(diagnosticOwner, "resyncRefused", 1)

				return false, "ClientNotReady"
			end

			local now: number = dependencies.Now()
			local window: Window? = windows[player]

			if window == nil or now - window.started >= options.windowSeconds then
				window = { started = now, attempts = 0, actors = {} }
				windows[player] = window
			end

			assert(window ~= nil, "Expected recovery admission window")

			if
				window.attempts >= options.maxRequestsPerClient
				or (window.actors[request.handle] or 0) >= options.maxRequestsPerActor
			then
				Metrics.Count(diagnosticOwner, "resyncRateLimited", 1)
				Metrics.Warn(diagnosticOwner, "ResyncAbuse", "ResyncRateLimited")
				Metrics.Count(diagnosticOwner, "resyncRefused", 1)

				return false, "ResyncRateLimited"
			end

			-- Charge attempts before awareness admission, bounding even unknown-handle floods.
			-- Only admitted handles get entries, bounding the per-window identity map.
			window.attempts += 1

			local accepted: boolean
			accepted, reason = dependencies.RequestReplacementBaseline(player, request.handle, "ActorViewDesynced")

			if accepted then
				Metrics.Count(diagnosticOwner, "resyncAdmitted", 1)
				window.actors[request.handle] = (window.actors[request.handle] or 0) + 1
			end

			if not accepted then
				Metrics.Count(diagnosticOwner, "resyncRefused", 1)

				if reason == "BaselineAlreadyPending" then
					Metrics.Count(diagnosticOwner, "resyncDeduplicated", 1)
				end
			end

			return accepted, reason
		end,
		Destroy = function(_self: Types.ResyncRuntime): ()
			if not destroyed then
				destroyed = true
				stopClosed()
				table.clear(windows)
			end
		end,
	}
end

return ResyncRuntime
