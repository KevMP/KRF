--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(ReplicatedStorage.Packages.KRF.server.Networking.types)
local Commands = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)
local Awareness = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: Commands.Fixture?

afterEach(function()
	Commands.destroy(fixture)
	fixture = nil
end)

it(
	"preserves the next turn and FIFO when a handler enqueues, replaces the next connection and adds a newcomer",
	function()
		local order: { string } = {}

		local command = Commands.definition("Game.Command")

		command.handle = function(context: Types.CommandContext): Types.CommandHandlerResult
			local current = assert(fixture, "Expected command fixture")

			local name = if context.player == current.player
				then "A"
				else if context.player == current.other then "B" else "C"

			table.insert(order, name .. context.requestId)

			if context.player == current.player and context.requestId == 1 then
				expect((current.runtime:Handle(current.player, Commands.request(current, 2, nil, nil, nil, nil)))).toBe(
					true
				)

				Awareness.close(current.base, current.other)
				Awareness.ready(current.base, current.other)

				expect((current.runtime:Handle(current.other, Commands.request(current, 1, nil, nil, nil, nil)))).toBe(
					true
				)

				local newcomer = Awareness.player(current.base)
				Awareness.ready(current.base, newcomer)
				expect((current.runtime:Handle(newcomer, Commands.request(current, 1, nil, nil, nil, nil)))).toBe(true)
				local dispatched, visits = current.runtime:Step()
				expect(dispatched).toBe(0)
				expect(visits).toBe(0)
			elseif context.player == current.player then
				expect(assert(context:GetPriorOutcome(1), "Previous result must precede the next handler").status).toBe(
					"Accepted"
				)
			end

			return { accepted = true }
		end

		local created = Commands.new({ command }, { maxDispatchRequests = 1, maxDispatchVisits = 1 })
		fixture = created
		expect((created.runtime:Handle(created.player, Commands.request(created, 1, nil, nil, nil, nil)))).toBe(true)
		expect((created.runtime:Handle(created.other, Commands.request(created, 10, nil, nil, nil, nil)))).toBe(true)

		for _ = 1, 4 do
			local dispatched, visits = created.runtime:Step()
			expect(dispatched).toBe(1)
			expect(visits).toBe(1)
		end

		expect(order).toEqual({ "A1", "A2", "B1", "C1" })
		local jobs, bytes = created.runtime:_GetPendingForTests()
		expect(jobs).toBe(0)
		expect(bytes).toBe(0)
		Awareness.close(created.base, created.player)
		Awareness.close(created.base, created.player)
		local dispatched, visits = created.runtime:Step()
		expect(dispatched).toBe(0)
		expect(visits).toBe(0)
		expect(created.faults).toEqual({})
	end
)
