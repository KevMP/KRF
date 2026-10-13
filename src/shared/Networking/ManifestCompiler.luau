--!strict
local ProtocolTypes = require(script.Parent.ProtocolTypes)

local ManifestCompiler = {} :: ProtocolTypes.ManifestCompiler

function ManifestCompiler.Reconstruct(
	_manifest: ProtocolTypes.ProtocolManifest
): (ProtocolTypes.ClientProtocol?, string?)
	return nil, "N2NotImplemented"
end

return ManifestCompiler
