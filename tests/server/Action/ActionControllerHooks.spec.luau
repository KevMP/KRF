--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = JestGlobals.it :: any
local expect = JestGlobals.expect

local ActionControllerHooks = require(KRF.server.Action.utils.ActionControllerHooks)

it("leaves a completed coroutine untouched during cleanup", function()
	local completedThread: thread = coroutine.create(function() end)
	coroutine.resume(completedThread)

	ActionControllerHooks.CancelSuspendedThread(completedThread)

	expect(coroutine.status(completedThread)).toBe("dead")
end)

it("closes a suspended coroutine that yielded directly", function()
	local suspendedThread: thread = coroutine.create(function()
		coroutine.yield()
	end)
	coroutine.resume(suspendedThread)

	ActionControllerHooks.CancelSuspendedThread(suspendedThread)

	expect(coroutine.status(suspendedThread)).toBe("dead")
end)
