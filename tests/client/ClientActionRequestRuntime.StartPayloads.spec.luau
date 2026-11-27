--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.ActionRequest.types)
local PayloadCodec = require(KRF.shared.ActionRequest.utils.ActionPayloadCodec)
local Utils = require(script.Parent.Utils.ActionRequestClientTestUtils)
local fixture: Utils.Fixture?

afterEach(function()
	Utils.destroy(fixture)
	fixture = nil
end)

it("pairs the admitted Start with the exact bytes sent, after its admission observers", function()
	local created: Utils.Fixture = Utils.new()
	fixture = created
	local order: { string } = {}
	local payloads: { Types.ActionStartPayload } = {}
	local parameters: any = { aim = { x = 1, y = 2, z = 3 } }

	created.runtime:ObserveStartPayloads(function(payload: Types.ActionStartPayload): ()
		table.insert(order, "Payload:" .. payload.admission.requestId)
		table.insert(payloads, payload)
	end)

	created.runtime:ObserveAdmissions(function(admission: Types.ActionRequestAdmission): ()
		table.insert(order, "Admitted:" .. admission.requestId)
	end)

	assert(created.runtime:Start(Utils.selection(created, "Combat.Fireball"), parameters))
	parameters.aim.x = 99

	expect(order).toEqual({ "Admitted:1", "Payload:1" })
	expect(created.port.order).toEqual({ "Sent:KRF.Action.Start:1" })
	local payload: Types.ActionStartPayload = payloads[1]
	expect(table.isfrozen(payload)).toBe(true)
	expect(payload.encoded).toBe(created.port.sent[1].request.payload)
	expect(payload.admission).toBe(created.runtime:GetOriginalStart(1))
	expect(payload.payload).toBe(created.catalog.requestsById["Combat.Fireball"].start)

	local decoded: boolean, value: any = PayloadCodec.Decode(payload.payload, payload.encoded)
	expect(decoded).toBe(true)
	expect(value).toEqual({ aim = { x = 1, y = 2, z = 3 } })
end)

it("builds no sidecar for a Start staged while nothing observed payloads, and never for follow-ups", function()
	local created: Utils.Fixture = Utils.new()
	fixture = created
	local payloads: { Types.ActionStartPayload } = {}
	local stop: (() -> ())? = nil

	local stopAdmissions: () -> () = created.runtime:ObserveAdmissions(function(): ()
		if stop == nil then
			stop = created.runtime:ObserveStartPayloads(function(payload: Types.ActionStartPayload): ()
				table.insert(payloads, payload)
			end)
		end
	end)

	assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))
	expect(stop ~= nil).toBe(true)
	stopAdmissions()
	assert(created.runtime:Stop(1))
	expect(#payloads).toBe(0)
	assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))
	expect(#payloads).toBe(1)
	expect(payloads[1].encoded).toBe("")
	assert(stop, "Expected a payload subscription")()
	assert(created.runtime:Start(Utils.selection(created, "Movement.Sprint")))
	expect(#payloads).toBe(1)
end)

it("delivers no sidecar for a Start refused before or during command admission", function()
	local created: Utils.Fixture = Utils.new()
	fixture = created
	local payloads: { Types.ActionStartPayload } = {}

	created.runtime:ObserveStartPayloads(function(payload: Types.ActionStartPayload): ()
		table.insert(payloads, payload)
	end)

	expect({ created.runtime:Start(Utils.selection(created, "Combat.Fireball"), { aim = "wrong" }) }).toEqual({
		nil,
		"ActionPayloadInvalid",
	})

	created.port.refusal = "CommandCapacityReached"

	expect({ created.runtime:Start(Utils.selection(created, "Combat.Fireball"), { aim = { x = 1, y = 1, z = 1 } }) }).toEqual({
		nil,
		"CommandCapacityReached",
	})

	created.port.refusal = nil
	created.port.refusalAfterAdmit = "ClientNotReady"

	expect({ created.runtime:Start(Utils.selection(created, "Combat.Fireball"), { aim = { x = 1, y = 1, z = 1 } }) }).toEqual({
		nil,
		"ClientNotReady",
	})

	expect(#payloads).toBe(0)
end)

it("stops delivering payloads once the runtime is destroyed", function()
	local created: Utils.Fixture = Utils.new()
	fixture = created
	created.runtime:Destroy()

	local stop: () -> () = created.runtime:ObserveStartPayloads(function(): ()
		error("Destroyed runtime delivered a payload")
	end)

	stop()

	expect({ created.runtime:Start(Utils.selection(created, "Movement.Sprint")) }).toEqual({
		nil,
		"ActionRequestRuntimeDestroyed",
	})
end)
