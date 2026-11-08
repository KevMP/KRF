--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local InputTypes = require(KRF.client.Input.types)
local SharedTypes = require(KRF.shared.ActionRequest.types)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Utils = require(script.Parent.Utils.ActionInputTestUtils)
local fixture: Utils.Fixture?

afterEach(function()
	Utils.destroy(fixture)
	fixture = nil
end)

local function startTogether(): (Utils.Fixture, { string }, { number }, { string })
	local created: Utils.Fixture = Utils.new()
	fixture = created
	local policies: Types.ActionInputPolicies = {}
	local schemas: SharedTypes.ActionRequestSchemas = {}
	local recognizers: { [string]: InputTypes.RecognizerDefinition } = {}
	local routes: { Types.ActionRoute } = {}
	local stops: { string } = {}

	for index = 1, 10 do
		local id: string = "Action" .. index

		schemas[id] = { stop = {}, allowInputInterrupt = true }

		policies[id] = {
			activation = "WhileDown",
			stopParameters = function(): any
				table.insert(stops, id)

				return nil
			end,
		}

		recognizers[id] = {
			inputs = { "AbilitySlot1" },
			maxWindowSeconds = 1,
			onEvent = function(_context, event): InputTypes.CustomMatch?
				return if event.kind == "Pressed" then {} else nil
			end,
		}

		table.insert(routes, Utils.route(id, { kind = "Custom", recognizerId = id }))
	end

	Utils.ready(created, policies, schemas)
	expect({ created.input.SetSource("Concurrent", { recognizers = recognizers }) }).toEqual({ true })
	Utils.set(created, routes)
	Utils.emit(created, "Pressed")
	local actions: { string } = {}
	local originals: { number } = {}

	for _, packet in Utils.packets(created) do
		expect(packet.kind).toBe("KRF.Action.Start")
		table.insert(actions, (assert(packet.actionId, "Expected selected Action")))
		table.insert(originals, packet.requestId)
	end

	expect(#originals).toBe(10)

	return created, actions, originals, stops
end

it("runs same-epoch Stop producers and sends Stops in original Start admission order", function()
	local created: Utils.Fixture, actions: { string }, originals: { number }, stops: { string } = startTogether()
	Utils.emit(created, "Released")
	expect(stops).toEqual(actions)
	local followed: { number } = {}

	for index, packet in Utils.packets(created) do
		if index > 10 then
			expect(packet.kind).toBe("KRF.Action.Stop")
			table.insert(followed, (assert(packet.originalStartRequestId, "Expected original receipt")))
		end
	end

	expect(followed).toEqual(originals)
end)

it("sends a batched Actor-switch retirement in original Start admission order", function()
	local created: Utils.Fixture, _actions: { string }, originals: { number }, stops: { string } = startTogether()
	expect({ Runtime.SetControlledActor(created.other) }).toEqual({ true })
	expect(stops).toEqual({})
	local followed: { number } = {}

	for index, packet in Utils.packets(created) do
		if index > 10 then
			expect(packet.kind).toBe("KRF.Action.Interrupt")
			table.insert(followed, (assert(packet.originalStartRequestId, "Expected original receipt")))
		end
	end

	expect(followed).toEqual(originals)
end)
