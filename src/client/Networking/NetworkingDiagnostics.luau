--!strict
local SideTypes = require(script.Parent.types)
local Types = require(script.Parent.Parent.Parent.shared.Networking.types)
local State = require(script.Parent.utils.NetworkingDiagnosticsState)
-- No mutation seam or historical identity references escape this facade.
local Diagnostics = {}

function Diagnostics.GetClientSnapshot(): Types.DiagnosticSnapshot?
	local owner = State.Get()

	return if owner ~= nil then owner:Snapshot() else nil
end

return table.freeze(Diagnostics) :: SideTypes.NetworkingDiagnostics
