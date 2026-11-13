--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local RequestTypes = require(KRF.shared.ActionRequest.types)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local Requests = require(KRF.client.ActionRequest.utils.ClientActionRequestState)
local Input = require(script.Parent.Utils.ActionInputTestUtils)
local Utils = require(script.Parent.Utils.ActionObservationTestUtils)
local fixture: Input.Fixture?
local disconnect: (() -> ())?

afterEach(function()
	if disconnect ~= nil then
		disconnect()
	end

	disconnect = nil
	Input.destroy(fixture)
	fixture = nil
end)

it(
	"measures physical-send and private-observation latency with and without a subscriber over mixed Action traffic",
	function()
		local created: Input.Fixture = Input.new()
		fixture = created
		local schemas: RequestTypes.ActionRequestSchemas = {}
		local policies: Types.ActionInputPolicies = {}
		local ids: { string } = {}

		for index = 1, 50 do
			local id: string = "Ability" .. index
			table.insert(ids, id)
			schemas[id] = { stop = {}, allowInputInterrupt = true }

			policies[id] =
				{ activation = if index % 3 == 0 then "Toggle" elseif index % 3 == 1 then "WhileDown" else "OneShot" }
		end

		local inputStarted: number = 0
		local measuring: boolean = false
		local send = created.commands.client.transport.SendReliable
		local sendLatencies: { number } = {}
		local observationLatencies: { number } = {}

		created.commands.client.transport.SendReliable = function(payload: buffer): ()
			if measuring then
				table.insert(sendLatencies, os.clock() - inputStarted)
			end

			send(payload)
		end

		Input.ready(created, policies, schemas)
		local selected: string = ids[1]

		Input.set(created, {
			{
				when = Input.key(),
				target = {
					kind = "Dynamic",
					resolve = function(): Types.ResolvedAction
						return { actionId = selected }
					end,
				},
			},
		})

		measuring = true
		local counts: { number } = {}

		for _, subscribed: boolean in { false, true } do
			if subscribed then
				disconnect = State.ObserveActionRequest(function(fact: Types.ActionRequestEvent): ()
					if fact.kind == "RequestAdmitted" then
						table.insert(observationLatencies, os.clock() - inputStarted)
					end
				end)
			end

			local armStart: number = #sendLatencies

			for _, id: string in ids do
				selected = id
				local first: number = #Input.packets(created) + 1
				inputStarted = os.clock()
				Input.tap(created)

				if policies[id].activation == "Toggle" then
					Input.tap(created)
				end

				local packets: { Input.Packet } = Input.packets(created)
				expect(#packets - first + 1).toBe(if policies[id].activation == "OneShot" then 1 else 2)

				if subscribed then
					-- Check before any wait/result delivery: a frame or RTT is not required.
					expect(#observationLatencies).toBe(#sendLatencies - armStart)
				end

				created.clock.Advance(0.01)

				for index = first, #packets do
					local packet: Input.Packet = packets[index]

					Utils.result(
						created,
						packet.requestId,
						if packet.kind == "KRF.Action.Start" then "Start" else "Stop",
						"Accepted",
						packet.requestId
					)

					task.wait()
				end

				Runtime.RetireRequest(packets[first].requestId)
				expect(assert(Requests.Get()):_GetRetainedCountForTests()).toBe(0)
			end

			table.insert(counts, #sendLatencies - armStart)
		end

		expect(counts[1]).toBe(counts[2])
		expect(counts[1] > #ids).toBe(true)
		expect(#observationLatencies).toBe(counts[2])

		print("__KRF_I8_LATENCY__ " .. HttpService:JSONEncode({
			actionIds = #ids,
			noSubscriberSends = counts[1],
			subscriberSends = counts[2],
			inputToPhysicalSendSeconds = sendLatencies,
			inputToPrivateAdmissionSeconds = observationLatencies,
		}))
	end
)
