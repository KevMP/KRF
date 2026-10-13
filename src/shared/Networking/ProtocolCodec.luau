--!strict
local ProtocolTypes = require(script.Parent.ProtocolTypes)
local Constants = require(script.Parent.ProtocolConstants)
local BootstrapCodec = require(script.Parent.utils.BootstrapCodec)
local BufferUtils = require(script.Parent.utils.CodecBufferUtils)

local ProtocolCodec = {} :: ProtocolTypes.ProtocolCodec
local codes: { [string]: number } = { Hello = 0, Bootstrap = 1, Ready = 2, ReadyAck = 3, Reject = 4 }
local rejectionReasons: { [number]: ProtocolTypes.RejectionReason } = {}
for reason: ProtocolTypes.RejectionReason, code: number in Constants.REJECTION_CODES do
	rejectionReasons[code] = reason
end

function ProtocolCodec.Encode(message: ProtocolTypes.Message): (buffer?, string?)
	local code: number? = codes[message.kind]
	if code == nil then
		return nil, "UnknownMessageKind"
	end
	if message.kind == "Bootstrap" then
		local completed: boolean, result: any = pcall(BootstrapCodec.Encode, message.manifest, code)
		if not completed then
			return nil,
				if result == "BootstrapTooLarge" or result == "UnsupportedSchema"
					then result
					else "InvalidProtocolManifest"
		end
		return result :: buffer, nil
	end
	local length: number = 1
	local reasonCode: number? = nil
	if message.kind == "Hello" then
		if type(message.version) ~= "number" or not BufferUtils.IsOffset(message.version, 65535) then
			return nil, "MalformedPacket"
		end
		length = 3
	elseif message.kind == "Reject" then
		if type(message.reason) ~= "string" then
			return nil, "ProtocolRejectionReasonInvalid"
		end
		reasonCode = Constants.REJECTION_CODES[message.reason]
		if reasonCode == nil then
			return nil, "ProtocolRejectionReasonInvalid"
		end
		length = Constants.REJECT_PACKET_BYTES
	end
	local destination: buffer = buffer.create(length)
	buffer.writeu8(destination, 0, code)
	if message.kind == "Hello" then
		buffer.writeu16(destination, 1, message.version)
	elseif reasonCode ~= nil then
		buffer.writeu8(destination, 1, reasonCode)
	end
	return destination, nil
end

function ProtocolCodec.Decode(payload: any): (ProtocolTypes.Message?, string?)
	if typeof(payload) ~= "buffer" then
		return nil, "ProtocolPayloadMustBeBuffer"
	end
	local length: number = buffer.len(payload)
	if length == 0 then
		return nil, "MalformedPacket"
	end
	local code: number = buffer.readu8(payload, 0)
	if code == codes.Bootstrap then
		if length > Constants.MAX_BOOTSTRAP_BYTES then
			return nil, "BootstrapTooLarge"
		end
		local completed: boolean, manifest: any = pcall(BootstrapCodec.Decode, payload)
		if not completed then
			return nil, manifest :: string
		end
		return { kind = "Bootstrap", manifest = manifest }, nil
	elseif code == codes.Hello then
		if length ~= 3 then
			return nil, "MalformedPacket"
		end
		return { kind = "Hello", version = buffer.readu16(payload, 1) }, nil
	elseif code == codes.Ready or code == codes.ReadyAck then
		if length ~= 1 then
			return nil, "MalformedPacket"
		end
		return if code == codes.Ready then { kind = "Ready" } else { kind = "ReadyAck" }, nil
	elseif code == codes.Reject then
		if length ~= Constants.REJECT_PACKET_BYTES then
			return nil, "MalformedPacket"
		end
		local reason: ProtocolTypes.RejectionReason? = rejectionReasons[buffer.readu8(payload, 1)]
		if reason == nil then
			return nil, "ProtocolRejectionReasonInvalid"
		end
		return { kind = "Reject", reason = reason }, nil
	end
	return nil, "UnknownMessageKind"
end

return ProtocolCodec
