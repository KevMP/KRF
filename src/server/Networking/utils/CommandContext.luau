--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)

-- One exact connection generation. The token is opaque and never reused by a reconnect;
-- closing observers run synchronously while N9 closes that generation.
export type ConnectionScope = {
	read token: unknown,
	read ObserveClosing: (callback: () -> ()) -> (() -> ())?,
}

type Binding = { ready: () -> boolean, owns: () -> boolean, scope: ConnectionScope }
local bindings: { [Types.CommandContext]: Binding } = setmetatable({}, { __mode = "k" })
local CommandContext = {}

function CommandContext.new(
	player: Player,
	actor: ActorTypes.Actor?,
	id: number,
	commandId: string,
	prior: (number) -> Types.CommandOutcome?,
	binding: Binding
): (Types.CommandContext, () -> ())
	local lookup: ((number) -> Types.CommandOutcome?)? = prior

	local context: Types.CommandContext = table.freeze({
		player = player,
		actor = actor,
		requestId = id,
		commandId = commandId,
		GetPriorOutcome = function(_self: Types.CommandContext, requestId: number): Types.CommandOutcome?
			local current = lookup

			return if current ~= nil then current(requestId) else nil
		end,
	})

	bindings[context] = binding

	return context, function(): ()
		lookup = nil
		bindings[context] = nil
	end
end

function CommandContext.IsReady(context: Types.CommandContext): boolean
	local binding: Binding? = bindings[context]

	return binding ~= nil and binding.ready()
end

function CommandContext.IsOwner(context: Types.CommandContext): boolean
	local binding: Binding? = bindings[context]

	return binding ~= nil and binding.ready() and binding.owns()
end

-- Framework-private: lets owners key state by the exact connection that sent a request.
function CommandContext.GetConnection(context: Types.CommandContext): unknown?
	local binding: Binding? = bindings[context]

	return if binding ~= nil and binding.ready() then binding.scope.token else nil
end

-- Returns nil once the generation is no longer current, so callers treat it as closed.
function CommandContext.ObserveConnectionClosing(context: Types.CommandContext, callback: () -> ()): (() -> ())?
	local binding: Binding? = bindings[context]

	if binding == nil or not binding.ready() then
		return nil
	end

	return binding.scope.ObserveClosing(callback)
end

return CommandContext
