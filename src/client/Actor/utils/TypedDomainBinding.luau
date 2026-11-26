--!strict
local Types = require(script.Parent.Parent.types)
local SignalTypes = require(script.Parent.Parent.Parent.Parent.shared.Signal.types)

local DomainBinding = {}

function DomainBinding.new(
	getDomain: () -> Types.DomainView?,
	connect: (Types.DomainView, () -> boolean, { SignalTypes.Connection }) -> ()
): (() -> (), () -> ())
	local current: Types.DomainView? = nil
	local connections: { SignalTypes.Connection } = {}

	local function disconnect(): ()
		current = nil

		for _, connection in connections do
			connection:Disconnect()
		end

		connections = {}
	end

	local function update(): ()
		local domain: Types.DomainView? = getDomain()

		if current == domain then
			return
		end

		disconnect()
		current = domain

		if domain ~= nil then
			local generation: { SignalTypes.Connection } = connections

			connect(domain, function(): boolean
				return connections == generation
			end, generation)
		end
	end

	update()

	return update, disconnect
end

function DomainBinding.Relay<Payload>(
	domain: Types.DomainView,
	id: string,
	signal: SignalTypes.Signal<Payload>,
	isCurrent: () -> boolean,
	connections: { SignalTypes.Connection },
	owned: SignalTypes.OwnedSignals
): ()
	local event: SignalTypes.Event<Payload>? = domain:GetEvent(id)
	assert(event ~= nil, "TypedViewMissingDomainEvent:" .. id)

	table.insert(
		connections,
		event:Connect(function(payload: Payload)
			if isCurrent() then
				owned:WithDeferredDestroy(function()
					signal:Fire(payload)
				end)
			end
		end)
	)
end

return DomainBinding
