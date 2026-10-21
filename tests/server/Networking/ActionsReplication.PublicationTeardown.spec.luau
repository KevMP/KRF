--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActionTypes = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local ActionUtils = require(script.Parent.Parent.Utils.Action.ActionResourceTestUtils)
local TestUtils = require(script.Parent.Parent.Utils.Networking.ActionsReplicationTestUtils)

local connections: { SignalTypes.Connection } = {}
local disconnect: () -> () = function() end

beforeEach(function()
	ActionUtils.reset()
	connections = {}
	disconnect = function() end
end)

afterEach(function()
	disconnect()

	for _, connection: SignalTypes.Connection in connections do
		connection:Disconnect()
	end

	ActionUtils.cleanup()
end)

for _, operation: string in { "Start", "End", "Interrupt" } do
	it(
		"finishes " .. operation .. " delivery when a publication observer destroys the controller and throws",
		function()
			local order: { string } = {}

			local definition: ActionTypes.ActionDefinition = TestUtils.action("Visible")

			definition.onStart = function()
				table.insert(order, "StartHook")
			end

			definition.onEnd = function()
				table.insert(order, "EndHook")
			end

			definition.onInterrupt = function(_context: ActionTypes.ActionExecutionContext, reason: string)
				table.insert(order, "InterruptHook:" .. reason)
			end

			TestUtils.initialize({ definition })
			local actor: ActorTypes.Actor, actions: ActionTypes.ActionController = ActionUtils.registerActor()

			table.insert(
				connections,
				actions.OnActionStarted:Connect(function()
					table.insert(order, "Started")
				end)
			)

			table.insert(
				connections,
				actions.OnActionEnded:Connect(function()
					table.insert(order, "Ended")
				end)
			)

			table.insert(
				connections,
				actions.OnActionInterrupted:Connect(function(event: ActionTypes.ActionInterruptedEvent)
					table.insert(order, "Interrupted:" .. event.reason)
				end)
			)

			if operation ~= "Start" then
				TestUtils.accept(actions, "Visible")
			end

			table.clear(order)
			local commits: { NetworkingTypes.PublicationCommit } = TestUtils.observe()
			local failureValue = { reason = "PublicationObserverDestroyedController" }
			local destroyed: boolean = false

			disconnect = TestUtils.publication():ObserveCommits(function()
				if not destroyed then
					destroyed = true
					actions:Destroy()
					error(failureValue, 0)
				end
			end)

			local success: boolean, failure: any = pcall(function()
				if operation == "Start" then
					actions:RequestAction("Visible")
				elseif operation == "End" then
					actions:EndAction(1)
				else
					actions:InterruptAction(1, "ServerReason")
				end
			end)

			expect(success).toBe(false)
			expect(failure).toBe(failureValue)
			expect(TestUtils.internal(actions):_getActiveReplicationState()).toEqual({})
			expect(TestUtils.state(actor)).toEqual({})
			expect(actions:RequestAction("Visible")).toEqual({ accepted = false, reason = "ActionControllerDestroyed" })

			if operation == "Start" then
				expect(order).toEqual({
					"Started",
					"Interrupted:ActionControllerDestroyed",
					"InterruptHook:ActionControllerDestroyed",
				})

				expect(#commits).toBe(2)
				expect(commits[1].sequence).toBe(1)
				expect(commits[2].sequence).toBe(2)

				expect(TestUtils.events(commits[1])).toEqual({
					{
						domainId = "KRF.Actions",
						eventId = "Started",
						payload = { actionId = "Visible", sequenceId = 1 },
					},
				})

				expect(TestUtils.events(commits[2])).toEqual({
					{
						domainId = "KRF.Actions",
						eventId = "Interrupted",
						payload = { actionId = "Visible", sequenceId = 1 },
					},
				})
			else
				expect(order).toEqual(
					if operation == "End"
						then { "Ended", "EndHook" }
						else { "Interrupted:ServerReason", "InterruptHook:ServerReason" }
				)

				expect(#commits).toBe(1)
				expect(commits[1].sequence).toBe(2)

				expect(TestUtils.events(commits[1])).toEqual({
					{
						domainId = "KRF.Actions",
						eventId = if operation == "End" then "Ended" else "Interrupted",
						payload = { actionId = "Visible", sequenceId = 1 },
					},
				})
			end

			local canSubscribe: boolean = pcall(function()
				actions.OnActionStarted:Connect(function() end)
			end)

			expect(canSubscribe).toBe(false)
			disconnect()
			actions:Destroy()
			expect(#commits).toBe(if operation == "Start" then 2 else 1)
		end
	)
end
