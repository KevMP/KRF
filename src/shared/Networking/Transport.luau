--!strict
local ProtocolTypes = require(script.Parent.ProtocolTypes)

local Transport = {
	ROOT_NAME = "_KRFNetworking",
	RELIABLE_NAME = "Reliable",
	UNRELIABLE_NAME = "Unreliable",
} :: ProtocolTypes.Transport

function Transport.Create(_parent: Instance): (ProtocolTypes.OwnedTransport?, string?)
	return nil, "N2NotImplemented"
end

function Transport.Locate(_parent: Instance): (ProtocolTypes.OwnedTransport?, string?)
	return nil, "N2NotImplemented"
end

return Transport
