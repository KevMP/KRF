--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local Authorization = require(KRF.server.Networking.CommandAuthorization)
local CommandContext = require(KRF.server.Networking.utils.CommandContext)
local TestUtils = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)
local AwarenessUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)

local fixture: TestUtils.Fixture? = nil

afterEach(function()
	TestUtils.destroy(fixture)
	fixture = nil
end)

type Capture = {
	contexts: { Types.CommandContext },
	connections: { unknown },
	closings: { string },
	disconnects: { () -> () },
}

-- Each handled request records its exact connection token and registers a closing observer.
local function setup(): (TestUtils.Fixture, Capture)
	local capture: Capture = { contexts = {}, connections = {}, closings = {}, disconnects = {} }

	local created: TestUtils.Fixture = TestUtils.new({
		{
			id = "Game.Command",
			target = "None",
			authorize = Authorization.AnyReadyClient,
			handle = function(context: Types.CommandContext): Types.CommandHandlerResult
				table.insert(capture.contexts, context)
				table.insert(capture.connections, CommandContext.GetConnection(context))

				local disconnect: (() -> ())? = CommandContext.ObserveConnectionClosing(context, function(): ()
					table.insert(capture.closings, "request" .. context.requestId)
				end)

				assert(disconnect ~= nil, "Expected a current connection generation")
				table.insert(capture.disconnects, disconnect)

				return { accepted = true }
			end,
		},
	})

	fixture = created

	return created, capture
end

it("exposes one opaque token per connection generation and a new one after reconnecting", function()
	local created: TestUtils.Fixture, capture: Capture = setup()
	TestUtils.send(created, 1)
	TestUtils.send(created, 2)
	expect(capture.connections[1]).never.toBeNil()
	expect(capture.connections[2]).toBe(capture.connections[1])

	AwarenessUtils.close(created.base, created.player)
	AwarenessUtils.ready(created.base, created.player)
	TestUtils.send(created, 1)
	expect(capture.connections[3]).never.toBeNil()
	expect(capture.connections[3]).never.toBe(capture.connections[1])
end)

it("runs closing observers synchronously once when the generation closes", function()
	local created: TestUtils.Fixture, capture: Capture = setup()
	TestUtils.send(created, 1)
	TestUtils.send(created, 2)
	expect(capture.closings).toEqual({})
	AwarenessUtils.close(created.base, created.player)
	expect(capture.closings).toEqual({ "request1", "request2" })
	AwarenessUtils.close(created.base, created.player)
	expect(capture.closings).toEqual({ "request1", "request2" })
end)

it("stops notifying a disconnected closing observer", function()
	local created: TestUtils.Fixture, capture: Capture = setup()
	TestUtils.send(created, 1)
	TestUtils.send(created, 2)
	capture.disconnects[2]()
	capture.disconnects[2]()
	AwarenessUtils.close(created.base, created.player)
	expect(capture.closings).toEqual({ "request1" })
end)

it("treats an escaped context as closed and refuses new closing observers", function()
	local created: TestUtils.Fixture, capture: Capture = setup()
	TestUtils.send(created, 1)
	local escaped: Types.CommandContext = capture.contexts[1]
	expect(CommandContext.GetConnection(escaped)).toBeNil()
	expect(CommandContext.ObserveConnectionClosing(escaped, function(): () end)).toBeNil()
end)

it("does not notify closing observers when the runtime itself is destroyed", function()
	local created: TestUtils.Fixture, capture: Capture = setup()
	TestUtils.send(created, 1)
	created.runtime:Destroy()
	expect(capture.closings).toEqual({})
end)
