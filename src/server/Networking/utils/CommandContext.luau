--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)

type Binding = { ready: () -> boolean, owns: () -> boolean }
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

return CommandContext
