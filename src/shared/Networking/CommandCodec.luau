--!strict
local Types = require(script.Parent.types)
local Constants = require(script.Parent.utils.CommandConstants)
local BufferUtils = require(script.Parent.utils.CodecBufferUtils)
local Value = require(script.Parent.utils.CommandValue)

local CommandCodec = {} :: Types.CommandCodecModule

local function counter(value: any): boolean
	return type(value) == "number" and value > 0 and BufferUtils.IsOffset(value, Constants.MAX_COUNTER)
end

local function payloadSize(codec: Types.CompiledCodec?, value: any): (number?, string?)
	if codec == nil then
		return if value == nil then 0 else nil, if value == nil then nil else "UnexpectedCommandPayload"
	end

	return codec.Measure(value)
end

local function readPayload(codec: Types.CompiledCodec?, source: buffer, offset: number): (any, string?)
	if codec == nil then
		return nil, if offset == buffer.len(source) then nil else "TrailingCommandBytes"
	end

	local value: any, nextOffset: number?, reason: string? = codec.Read(source, offset, buffer.len(source))

	if nextOffset == nil then
		return nil, reason or "MalformedCommandPayload"
	end

	if nextOffset ~= buffer.len(source) then
		return nil, "TrailingCommandBytes"
	end

	return Value.Freeze(value), nil
end

function CommandCodec.Compile(protocol: Types.ClientProtocol): Types.CommandCodec
	local commands: { [number]: Types.ClientCommand } = protocol.commandsByCode or {}

	local function header(
		payload: any,
		kind: number,
		minimum: number,
		maximum: number
	): (Types.ClientCommand?, number?, string?)
		if
			typeof(payload) ~= "buffer"
			or buffer.len(payload) < minimum
			or buffer.len(payload) > maximum
			or buffer.readu8(payload, 0) ~= kind
		then
			return nil, nil, "MalformedCommandEnvelope"
		end

		local command: Types.ClientCommand? = commands[buffer.readu16(payload, 1)]
		local requestId: number = buffer.readu32(payload, 3)

		if command == nil or requestId == 0 then
			return nil, nil, if command == nil then "UnknownCommandCode" else "InvalidRequestId"
		end

		return command, requestId, nil
	end

	local function writeHeader(destination: buffer, kind: number, code: number, requestId: number): ()
		buffer.writeu8(destination, 0, kind)
		buffer.writeu16(destination, 1, code)
		buffer.writeu32(destination, 3, requestId)
	end

	local codec: Types.CommandCodec = {
		EncodeRequest = function(request: Types.CommandRequest): (buffer?, string?)
			local command: Types.ClientCommand? = commands[request.commandCode]

			if command == nil or not counter(request.requestId) then
				return nil, if command == nil then "UnknownCommandCode" else "InvalidRequestId"
			end

			if
				(command.target == "Actor" and not counter(request.targetHandle))
				or (command.target == "None" and request.targetHandle ~= nil)
			then
				return nil, "CommandTargetMismatch"
			end

			local size: number?, reason: string? = payloadSize(command.requestCodec, request.request)

			if size == nil then
				return nil, reason
			end

			if size > Constants.MAX_PAYLOAD_BYTES then
				return nil, "CommandPayloadTooLarge"
			end

			local destination: buffer = buffer.create(11 + size)
			writeHeader(destination, Constants.REQUEST_KIND, command.code, request.requestId)
			buffer.writeu32(destination, 7, request.targetHandle or 0)

			if command.requestCodec ~= nil then
				local offset: number?, writeReason: string? =
					command.requestCodec.Write(request.request, destination, 11)

				if offset == nil then
					return nil, writeReason
				end
			end

			return destination, nil
		end,
		DecodeRequest = function(payload: any): (Types.CommandRequest?, string?)
			local command: Types.ClientCommand?, requestId: number?, reason: string? =
				header(payload, Constants.REQUEST_KIND, 11, Constants.MAX_REQUEST_BYTES)

			if command == nil or requestId == nil then
				return nil, reason
			end

			local handle: number = buffer.readu32(payload, 7)

			if (command.target == "Actor" and handle == 0) or (command.target == "None" and handle ~= 0) then
				return nil, "CommandTargetMismatch"
			end

			local request: any, payloadReason: string? = readPayload(command.requestCodec, payload, 11)

			if payloadReason ~= nil then
				return nil, payloadReason
			end

			return table.freeze({
				commandCode = command.code,
				requestId = requestId,
				targetHandle = if handle > 0 then handle else nil,
				request = request,
			}),
				nil
		end,
		EncodeResult = function(outcome: Types.CommandResult): (buffer?, string?)
			local command: Types.ClientCommand? = commands[outcome.commandCode]

			if command == nil or not counter(outcome.requestId) then
				return nil, if command == nil then "UnknownCommandCode" else "InvalidRequestId"
			end

			local status: number? = if outcome.status == "Accepted"
				then 0
				elseif outcome.status == "Rejected" then 1
				elseif outcome.status == "Unknown" then 2
				else nil

			if status == nil then
				return nil, "InvalidCommandStatus"
			end

			local size: number? = nil
			local reason: string? = nil

			if status == 0 then
				if outcome.reason ~= nil then
					return nil, "InvalidCommandResult"
				end

				size, reason = payloadSize(command.resultCodec, outcome.result)
			else
				if
					outcome.result ~= nil
					or type(outcome.reason) ~= "string"
					or #outcome.reason == 0
					or #outcome.reason > Constants.MAX_REASON_BYTES
				then
					return nil, "InvalidCommandReason"
				end

				size = 1 + #outcome.reason
			end

			if size == nil or size > Constants.MAX_PAYLOAD_BYTES then
				return nil, reason or "CommandPayloadTooLarge"
			end

			local destination: buffer = buffer.create(8 + size)
			writeHeader(destination, Constants.RESULT_KIND, command.code, outcome.requestId)
			buffer.writeu8(destination, 7, status)

			if status == 0 and command.resultCodec ~= nil then
				local offset: number?, writeReason: string? = command.resultCodec.Write(outcome.result, destination, 8)

				if offset == nil then
					return nil, writeReason
				end
			elseif status ~= 0 then
				local rejection: string = outcome.reason :: string
				buffer.writeu8(destination, 8, #rejection)
				buffer.writestring(destination, 9, rejection)
			end

			return destination, nil
		end,
		DecodeResult = function(payload: any): (Types.CommandResult?, string?)
			local command: Types.ClientCommand?, requestId: number?, reason: string? =
				header(payload, Constants.RESULT_KIND, 8, Constants.MAX_RESULT_BYTES)

			if command == nil or requestId == nil then
				return nil, reason
			end

			local status: number = buffer.readu8(payload, 7)

			if status == 0 then
				local value: any, payloadReason: string? = readPayload(command.resultCodec, payload, 8)

				if payloadReason ~= nil then
					return nil, payloadReason
				end

				local accepted: Types.CommandResult = {
					commandCode = command.code,
					requestId = requestId,
					status = "Accepted",
					result = value,
				}

				return table.freeze(accepted), nil
			end

			if status > 2 or buffer.len(payload) < 9 then
				return nil, "MalformedCommandResult"
			end

			local length: number = buffer.readu8(payload, 8)

			if length == 0 or length > Constants.MAX_REASON_BYTES or buffer.len(payload) ~= 9 + length then
				return nil, "MalformedCommandReason"
			end

			local rejected: Types.CommandResult = {
				commandCode = command.code,
				requestId = requestId,
				status = if status == 1 then "Rejected" else "Unknown",
				reason = buffer.readstring(payload, 9, length),
			}

			return table.freeze(rejected), nil
		end,
	}

	return table.freeze(codec)
end

return CommandCodec
