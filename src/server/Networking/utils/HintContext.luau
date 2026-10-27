--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
type Binding = { ready: () -> boolean, owns: () -> boolean }
local bindings: { [Types.HintContext]: Binding } = setmetatable({}, { __mode = "k" })
local HintContext = {}

function HintContext.new(player: Player, actor: ActorTypes.Actor?, id: string, binding: Binding): Types.HintContext
	local context: Types.HintContext = table.freeze({ player = player, actor = actor, hintId = id })

	bindings[context] = binding

	return context
end

function HintContext.Release(context: Types.HintContext): ()
	bindings[context] = nil
end

function HintContext.IsReady(context: Types.HintContext): boolean
	local binding = bindings[context]

	return binding ~= nil and binding.ready()
end

function HintContext.IsOwner(context: Types.HintContext): boolean
	local binding = bindings[context]

	return binding ~= nil and binding.ready() and binding.owns()
end

function HintContext.Resume(thread: thread, ...: any): (boolean, any)
	local completed, result = coroutine.resume(thread, ...)

	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)

		return false, nil
	end

	return completed, result
end

return HintContext
