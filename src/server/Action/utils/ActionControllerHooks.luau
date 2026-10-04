--!strict
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)

type Actor = ActorTypes.Actor

local ActionControllerHooks = {}

function ActionControllerHooks.CancelSuspendedThread(threadToCancel: thread): ()
	if coroutine.status(threadToCancel) ~= "suspended" then
		return
	end
	pcall(task.cancel, threadToCancel)
	pcall(coroutine.close, threadToCancel)
end

function ActionControllerHooks.RunNonSuspending(
	callback: (...any) -> ...any,
	...: any
): (boolean, any, any, string?, any)
	local callbackThread: thread = coroutine.create(callback)
	local resumed: boolean, first: any, second: any = coroutine.resume(callbackThread, ...)
	if not resumed then
		return false, nil, nil, "Error", first
	end
	if coroutine.status(callbackThread) ~= "dead" then
		ActionControllerHooks.CancelSuspendedThread(callbackThread)
		return false, nil, nil, "Yielded", nil
	end
	return true, first, second, nil, nil
end

function ActionControllerHooks.WarnFailure(actor: Actor, actionId: string, hookName: string, detail: any): ()
	warn(
		"[ActionController] "
			.. hookName
			.. " failed actorId="
			.. actor:GetId()
			.. " actionId="
			.. actionId
			.. " reason="
			.. tostring(detail)
	)
end

return ActionControllerHooks
