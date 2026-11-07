--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.client.Actor.types)
local Registry = require(KRF.client.Actor.utils.ActorViewRegistryState)
local Utils = require(script.Parent.Utils.ActorViewTestUtils)
local fixture: Utils.Fixture
local disconnects: { () -> () }
local blocked: { thread }

beforeEach(function()
	fixture = Utils.new()
	disconnects = {}
	blocked = {}
end)

afterEach(function()
	for _, disconnect in disconnects do
		disconnect()
	end

	for _, worker: thread in blocked do
		if coroutine.status(worker) ~= "dead" then
			coroutine.close(worker)
		end
	end

	Utils.destroy(fixture)
	Registry.Reset()
end)

for _, path: string in { "Halt", "Remove", "Reset" } do
	it("runs the private " .. path .. " barrier before publishing an unavailable or removed identity", function()
		Utils.baseline(fixture)
		local actor: ActorTypes.ActorView = Utils.view(fixture)
		local trace: { string } = {}
		local delivered: boolean = false

		local function deferredPublic(): ()
			table.insert(blocked, coroutine.running())
			coroutine.yield()
			delivered = true
		end

		table.insert(fixture.connections, actor.OnUnavailable:Connect(deferredPublic))
		table.insert(fixture.connections, fixture.runtime.registry.OnActorViewRemoving:Connect(deferredPublic))

		table.insert(
			disconnects,
			Registry.ObserveInvalidation(function(view: ActorTypes.ActorView, reason: string): ()
				expect(view).toBe(actor)
				expect(view:IsAvailable()).toBe(true)
				expect(Registry.IsCurrent(view)).toBe(true)
				expect(delivered).toBe(false)
				table.insert(trace, reason)
			end)
		)

		if path == "Halt" then
			fixture.runtime.consumer.OnActorHalted(Utils.actor(fixture))
		elseif path == "Remove" then
			fixture.runtime.consumer.OnActorRemoved(Utils.actor(fixture))
		else
			Registry.Reset()
		end

		expect(trace).toEqual({
			if path == "Halt" then "ActorStreamHalted" elseif path == "Remove" then "ActorRemoved" else "RegistryReset",
		})

		if path == "Halt" then
			expect(actor:IsAvailable()).toBe(false)
		else
			expect(Registry.IsCurrent(actor)).toBe(false)
		end
	end)
end

it("contains throwing and yielding private invalidation observers and continues all cleanup", function()
	Utils.baseline(fixture)
	local actor: ActorTypes.ActorView = Utils.view(fixture)

	table.insert(
		disconnects,
		Registry.ObserveInvalidation(function()
			error("PrivateBarrierFailure", 0)
		end)
	)

	table.insert(
		disconnects,
		Registry.ObserveInvalidation(function()
			coroutine.yield()
		end)
	)

	local calls: number = 0

	table.insert(
		disconnects,
		Registry.ObserveInvalidation(function()
			calls += 1
		end)
	)

	fixture.runtime.consumer.OnActorRemoved(Utils.actor(fixture))
	expect(calls).toBe(1)
	expect(Registry.IsCurrent(actor)).toBe(false)
	expect(actor:IsAvailable()).toBe(false)
end)

it("disconnects private barriers idempotently without reviving them for a later Actor identity", function()
	Utils.baseline(fixture)
	local calls: number = 0

	local stop = Registry.ObserveInvalidation(function()
		calls += 1
	end)

	stop()
	stop()
	fixture.runtime.consumer.OnActorRemoved(Utils.actor(fixture))
	Utils.baseline(fixture, 2, "ActorB")
	fixture.runtime.consumer.OnActorRemoved(Utils.actor(fixture, 2))
	expect(calls).toBe(0)
end)
