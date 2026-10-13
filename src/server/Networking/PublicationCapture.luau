--!strict
local PublicationTypes = require(script.Parent.PublicationTypes)
local SchemaTypes = require(script.Parent.Parent.Parent.shared.Networking.types)

local PublicationCapture = {}
local CapturePlan = {}
CapturePlan.__index = CapturePlan

function PublicationCapture.Compile(_schema: SchemaTypes.CompiledSchema): PublicationTypes.CapturePlan
	return setmetatable({}, CapturePlan) :: any
end

function CapturePlan.Capture(
	_self: PublicationTypes.CapturePlan,
	_value: any,
	_previous: PublicationTypes.CaptureResult?
): (PublicationTypes.CaptureResult?, string?)
	error("N3NotImplemented", 2)
end

return PublicationCapture
