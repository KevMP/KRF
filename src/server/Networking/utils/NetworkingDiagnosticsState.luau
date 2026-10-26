--!strict
local Types = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local State = {}
local server: Types.DiagnosticCollector? = nil
local connections: { [Player]: Types.DiagnosticCollector } = {}

function State.Start(): ()
	State.Stop()
	local owner = Metrics.new("Server", nil)
	server = owner

	local keys: { Types.DiagnosticAge } = {
		"reliableEligibleQueueAgeSeconds",
		"commandQueueAgeSeconds",
		"hintSendQueueAgeSeconds",
		"hintReceiveQueueAgeSeconds",
	}

	for _, key in keys do
		owner:SetAgeSource(key, function(): number?
			local oldest: number? = nil

			for _, connection in connections do
				local age = connection:GetAge(key)

				if age ~= nil then
					oldest = math.max(oldest or 0, age)
				end
			end

			return oldest
		end)
	end
end

function State.GetServer(): Types.DiagnosticCollector?
	return server
end

function State.GetConnection(player: Player): Types.DiagnosticCollector?
	local owner = server

	if owner == nil then
		return nil
	end

	local connection = connections[player]

	if connection == nil then
		connection = Metrics.new("Connection", owner)
		connections[player] = connection
		owner:Adjust("connections", 1)
	end

	return connection
end

function State.FindConnection(player: Player): Types.DiagnosticCollector?
	return connections[player]
end

function State.Close(player: Player): ()
	if connections[player] ~= nil then
		connections[player]:ClearSources()
		connections[player] = nil
		Metrics.Adjust(server, "connections", -1)
	end
end

function State.Stop(): ()
	if server ~= nil then
		server:ClearSources()
	end

	for _, connection in connections do
		connection:ClearSources()
	end

	table.clear(connections)
	server = nil
end

return State
