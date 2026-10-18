--!strict
local Types = require(script.Parent.Parent.types)
local Resync = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ResyncCodec)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)

export type Recovery = { Start: () -> (), Cancel: () -> () }

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
	local active: boolean = false
	local episode: number = 0
	local deadline: number = 0
	local cancelTimer: (() -> ())? = nil
	local started: number = options.Now()
	local requests: number = 0

	local function cancel(): ()
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
			return
		end

		requests += 1
		local payload: buffer?, reason: string? = Resync.Encode(actor.handle)

		if payload == nil then
			cancel()
			exhausted(reason or "InvalidActorHandle")

			return
		end

		local sent: boolean, sendReason: any = pcall(options.SendReliable, payload)

		if not sent then
			report("ResyncSendFailed:" .. tostring(sendReason))
		end
	end

	return {
		Start = function(): ()
			if active then
				return
			end

			active = true
			episode += 1
			deadline = options.Now() + 31
			attempt(episode, 1)
		end,
		Cancel = cancel,
	}
end

return ActorViewRecovery
