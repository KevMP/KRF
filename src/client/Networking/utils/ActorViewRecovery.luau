--!strict
local Types = require(script.Parent.Parent.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Diagnostics = require(script.Parent.NetworkingDiagnosticsState)
local Resync = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ResyncCodec)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)

export type Recovery = { Start: () -> (), Cancel: (boolean?) -> () }

local ActorViewRecovery = {}
-- Five opportunities at 0, 1, 3, 7 and 15 seconds; exhaustion at 31 seconds.
-- The final opportunity crosses the server's ten-second admission window.
local delays: { number } = table.freeze({ 1, 2, 4, 8, 16 })

function ActorViewRecovery.Admission(now: () -> number): () -> boolean
	local started: number = now()
	local requests: number = 0

	return function(): boolean
		local current: number = now()

		if current - started >= Constants.RESYNC_WINDOW_SECONDS then
			started = current
			requests = 0
		end

		if requests >= Constants.MAX_RESYNC_PER_CLIENT then
			return false
		end

		requests += 1

		return true
	end
end

function ActorViewRecovery.new(
	options: Types.ActorViewOptions,
	actor: Types.ActorStreamRecord,
	admit: () -> boolean,
	report: (string) -> (),
	exhausted: (string) -> ()
): Recovery
	local diagnostics = Diagnostics.Get()
	local active: boolean = false
	local episode: number = 0
	local deadline: number = 0
	local cancelTimer: (() -> ())? = nil
	local started: number = options.Now()
	local requests: number = 0

	local function cancel(completed: boolean?): ()
		if active then
			Metrics.Adjust(diagnostics, "recoveryStreams", -1)

			if not completed then
				Metrics.Count(diagnostics, "recoveryAbandoned", 1)
			end
		end

		active = false
		episode += 1
		local pending: (() -> ())? = cancelTimer
		cancelTimer = nil

		if pending ~= nil then
			pending()
		end
	end

	local function attempt(token: number, opportunity: number): ()
		if not active or token ~= episode then
			return
		end

		local current: number = options.Now()

		if opportunity > #delays or current >= deadline then
			cancel()
			exhausted("ActorRecoveryExhausted")

			return
		end

		Metrics.Count(diagnostics, "resyncRequests", 1)
		Metrics.Count(diagnostics, "recoveryBackoffs", 1)

		-- Schedule before sending so synchronous replacement can cancel the timer.
		cancelTimer = options.ScheduleTimeout(math.min(delays[opportunity], deadline - current), function()
			if not active or token ~= episode then
				return
			end

			cancelTimer = nil
			attempt(token, opportunity + 1)
		end)

		if current - started >= Constants.RESYNC_WINDOW_SECONDS then
			started = current
			requests = 0
		end

		if requests >= Constants.MAX_RESYNC_PER_ACTOR or not admit() then
			Metrics.Count(diagnostics, "resyncRateLimited", 1)
			Metrics.Count(diagnostics, "resyncRefused", 1)

			return
		end

		requests += 1
		local payload: buffer?, reason: string? = Resync.Encode(actor.handle)

		if payload == nil then
			Metrics.Count(diagnostics, "resyncRefused", 1)
			cancel()
			exhausted(reason or "InvalidActorHandle")

			return
		end

		Metrics.Count(diagnostics, "resyncAdmitted", 1)
		local sent: boolean, sendReason: any = pcall(options.SendReliable, payload)

		if not sent then
			report("ResyncSendFailed:" .. tostring(sendReason))
		end
	end

	return {
		Start = function(): ()
			if active then
				Metrics.Count(diagnostics, "resyncRequests", 1)
				Metrics.Count(diagnostics, "resyncDeduplicated", 1)
				Metrics.Count(diagnostics, "resyncRefused", 1)

				return
			end

			active = true
			Metrics.Adjust(diagnostics, "recoveryStreams", 1)
			episode += 1
			deadline = options.Now() + 31
			attempt(episode, 1)
		end,
		Cancel = cancel,
	}
end

return ActorViewRecovery
