--!strict
local Types = require(script.Parent.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Hints = require(script.Parent.Parent.ClientHintRuntime)
local HintReceiver = require(script.Parent.HintReceiver)
local HintState = require(script.Parent.HintRuntimeState)
local ViewRegistry = require(script.Parent.Parent.Parent.Actor.ActorViewRegistry)
local Installation = {}

-- Own both disposable lanes and all observers as one installation lifetime.
-- Reliable stream/view ownership remains with the consumer installation.
function Installation.Install(
	protocol: SharedNetworkingTypes.ClientProtocol,
	created: Types.ActorStreamRuntime,
	options: Types.ClientConsumerInstallationOptions
): () -> ()
	local hints: Types.ClientHintRuntime? = nil
	local hintReceiver: Types.HintReceiverRuntime? = nil
	local stopUnreliable: (() -> ())? = nil
	local stopHints: (() -> ())? = nil
	local removedHintActor: SignalTypes.Connection? = nil

	local active = true

	local function cleanup(): ()
		if not active then
			return
		end

		active = false
		HintState.Install(nil)
		HintState.Disconnect()

		if stopUnreliable ~= nil then
			stopUnreliable()
			stopUnreliable = nil
		end

		if hintReceiver ~= nil then
			hintReceiver:Destroy()
			hintReceiver = nil
		end

		if stopHints ~= nil then
			stopHints()
			stopHints = nil
		end

		if removedHintActor ~= nil then
			removedHintActor:Disconnect()
			removedHintActor = nil
		end

		if hints ~= nil then
			hints:Destroy()
			hints = nil
		end
	end

	local success, reason = pcall(function(): ()
		local hasC2S, hasS2C = false, false

		for _, hint in protocol.hintsById or {} do
			if hint.direction == "ClientToServer" then
				hasC2S = true
			else
				hasS2C = true
			end
		end

		if hasC2S then
			assert(options.sendUnreliable ~= nil and options.isReady ~= nil, "HintUnreliableEndpointMissing")

			local hintRuntime = Hints.new(protocol, created, {
				Now = options.Now,
				IsReady = options.isReady,
				SendUnreliable = options.sendUnreliable,
			})

			hints = hintRuntime
			HintState.Install(hintRuntime)
		end

		if hasS2C then
			assert(options.connectUnreliable ~= nil and options.isReady ~= nil, "HintUnreliableEndpointMissing")

			local receiver = HintReceiver.new(protocol, created, {
				Now = options.Now,
				IsReady = options.isReady,
				Notify = HintState.Notify,
			})

			hintReceiver = receiver :: Types.HintReceiverRuntime

			stopUnreliable = options.connectUnreliable(function(payload: any, ...: any): ()
				receiver:Handle(payload, ...)
			end)
		end

		if hasC2S or hasS2C then
			removedHintActor = ViewRegistry.OnActorViewRemoving:Connect(function(actor): ()
				if hints ~= nil then
					hints:ForgetActor(actor)
				end

				if hintReceiver ~= nil then
					hintReceiver:ForgetActor(actor)
				end
			end)

			local observe = options.ObserveStep

			if observe ~= nil then
				stopHints = observe(function(): ()
					if hints ~= nil then
						hints:Step()
					end

					if hintReceiver ~= nil then
						hintReceiver:Step()
					end
				end)
			end
		end
	end)

	if not success then
		cleanup()
		error(reason, 0)
	end

	return cleanup
end

return Installation
