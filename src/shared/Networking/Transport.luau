--!strict
local ProtocolTypes = require(script.Parent.ProtocolTypes)

local Transport = {
	ROOT_NAME = "_KRFNetworking",
	RELIABLE_NAME = "Reliable",
	UNRELIABLE_NAME = "Unreliable",
} :: ProtocolTypes.Transport

local function named(parent: Instance, name: string): { Instance }
	local children: { Instance } = {}
	for _, child: Instance in parent:GetChildren() do
		if child.Name == name then
			table.insert(children, child)
		end
	end
	return children
end

local function view(
	root: Folder,
	reliable: RemoteEvent,
	unreliable: UnreliableRemoteEvent,
	owns: boolean
): ProtocolTypes.OwnedTransport
	local destroyed: boolean = false
	return {
		root = root,
		reliable = reliable,
		unreliable = unreliable,
		Destroy = function(): ()
			if destroyed then
				return
			end
			destroyed = true
			if owns then
				root:Destroy()
			end
		end,
	}
end

function Transport.Create(parent: Instance): (ProtocolTypes.OwnedTransport?, string?)
	if #named(parent, Transport.ROOT_NAME) ~= 0 then
		return nil, "TransportConflict"
	end
	local root: Folder = Instance.new("Folder")
	root.Name = Transport.ROOT_NAME
	local reliable: RemoteEvent = Instance.new("RemoteEvent")
	reliable.Name = Transport.RELIABLE_NAME
	reliable.Parent = root
	local unreliable: UnreliableRemoteEvent = Instance.new("UnreliableRemoteEvent")
	unreliable.Name = Transport.UNRELIABLE_NAME
	unreliable.Parent = root
	local completed: boolean, reason: any = pcall(function()
		root.Parent = parent
	end)
	if not completed then
		root:Destroy()
		error(reason, 2)
	end
	return view(root, reliable, unreliable, true), nil
end

function Transport.Locate(parent: Instance): (ProtocolTypes.OwnedTransport?, string?)
	local roots: { Instance } = named(parent, Transport.ROOT_NAME)
	if #roots == 0 then
		return nil, "TransportUnavailable"
	end
	if #roots ~= 1 or not roots[1]:IsA("Folder") then
		return nil, "InvalidTransport"
	end
	local root: Folder = roots[1] :: Folder
	local reliable: { Instance } = named(root, Transport.RELIABLE_NAME)
	local unreliable: { Instance } = named(root, Transport.UNRELIABLE_NAME)
	if
		#root:GetChildren() ~= 2
		or #reliable ~= 1
		or #unreliable ~= 1
		or reliable[1].ClassName ~= "RemoteEvent"
		or unreliable[1].ClassName ~= "UnreliableRemoteEvent"
	then
		return nil, "InvalidTransport"
	end
	return view(root, reliable[1] :: RemoteEvent, unreliable[1] :: UnreliableRemoteEvent, false), nil
end

return Transport
