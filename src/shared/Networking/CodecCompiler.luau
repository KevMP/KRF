--!strict
local NetworkingTypes = require(script.Parent.types)

local CodecCompiler = {} :: NetworkingTypes.CodecCompiler

function CodecCompiler.Compile(_schema: NetworkingTypes.CompiledSchema): (NetworkingTypes.CompiledCodec?, string?)
	return nil, "N2NotImplemented"
end

return CodecCompiler
