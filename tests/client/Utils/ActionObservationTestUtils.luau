--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local Types = require(KRF.client.Action.types)
local SignalTypes = require(KRF.shared.Signal.types)
local WireTypes = require(KRF.shared.Networking.types)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local CommandCodec = require(KRF.shared.Networking.CommandCodec)
local Input = require(script.Parent.ActionInputTestUtils)

export type Capture = {
	private: { Types.ActionRequestEvent },
	public: { Types.ActionRequestEvent },
	disconnect: () -> (),
}

local Utils = {}

function Utils.capture(): Capture
	local private: { Types.ActionRequestEvent } = {}
	local public: { Types.ActionRequestEvent } = {}

	local stop = State.ObserveActionRequest(function(fact: Types.ActionRequestEvent): ()
		table.insert(private, fact)
	end)

	local connection: SignalTypes.Connection = Runtime.OnActionRequest:Connect(
		function(fact: Types.ActionRequestEvent): ()
			table.insert(public, fact)
		end
	)

	return {
		private = private,
		public = public,
		disconnect = function(): ()
			stop()
			connection:Disconnect()
		end,
	}
end

function Utils.fact(facts: { Types.ActionRequestEvent }, index: number): Types.ActionRequestEvent
	expect(#facts >= index).toBe(true)

	return assert(facts[index], "Expected a normalized Action observation on the original call stack")
end

function Utils.kinds(facts: { Types.ActionRequestEvent }): { string }
	local kinds: { string } = {}

	for _, fact: Types.ActionRequestEvent in facts do
		table.insert(
			kinds,
			if fact.kind == "InputTransition" then fact.transition else fact.kind .. ":" .. fact.operation
		)
	end

	return kinds
end

-- Inject at the real reliable receiver without yielding, including during Send.
function Utils.result(
	fixture: Input.Fixture,
	requestId: number,
	operation: Types.ActionRequestOperation,
	status: "Accepted" | "Rejected",
	sequenceId: number?,
	reason: string?
): ()
	local protocol: WireTypes.ClientProtocol = assert(fixture.commands.protocol, "Expected installed protocol")
	local commands = assert(protocol.commandsById, "Expected command codebook")

	local payload: buffer = assert(CommandCodec.Compile(protocol).EncodeResult({
		commandCode = commands["KRF.Action." .. operation].code,
		requestId = requestId,
		status = status,
		result = if operation == "Start" and status == "Accepted" then { sequenceId = sequenceId or 7 } else nil,
		reason = reason,
	}))

	assert(fixture.commands.client.inbound, "Expected reliable receiver")(payload)
end

function Utils.parity(capture: Capture): ()
	task.wait()
	local sorted: { Types.ActionRequestEvent } = table.clone(capture.public)

	table.sort(sorted, function(left: Types.ActionRequestEvent, right: Types.ActionRequestEvent): boolean
		return left.eventOrdinal < right.eventOrdinal
	end)

	expect(#sorted).toBe(#capture.private)

	for index, fact: Types.ActionRequestEvent in sorted do
		local allowed: { [string]: boolean } = {
			actor = true,
			actionId = true,
			originalStartRequestId = true,
			originalStartKey = true,
			origin = true,
			kind = true,
			eventOrdinal = true,
			observedAt = true,
		}

		if fact.kind == "InputTransition" then
			allowed.transition, allowed.reason = true, true
		else
			allowed.operation, allowed.requestId, allowed.requestKey = true, true, true

			if fact.kind == "RequestAdmitted" then
				allowed.inputOccurredAt = true
			else
				allowed.status, allowed.sequenceId, allowed.reason = true, true, true
			end
		end

		local publicFields = (fact :: unknown) :: { [string]: unknown }
		local privateFields = (capture.private[index] :: unknown) :: { [string]: unknown }

		for key: string in publicFields do
			expect(allowed[key]).toBe(true)
		end

		for key: string in allowed do
			expect(publicFields[key]).toEqual(privateFields[key])
		end

		expect(table.isfrozen(fact)).toBe(true)
	end
end

return Utils
