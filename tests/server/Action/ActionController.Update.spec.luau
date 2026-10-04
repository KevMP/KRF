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
local ActionRegistry = require(KRF.server.Action.ActionRegistry)
local ActionControllerModule = require(KRF.server.Action.ActionController)
local ActorEntity = require(KRF.server.Actor.ActorEntity)

type ActionDefinition = ActionTypes.ActionDefinition
type ActionExecutionContext = ActionTypes.ActionExecutionContext
type Actor = ActorTypes.Actor

local now: number = 100
local controllers: { any } = {}

local function loadFactory(factory: ActionTypes.ActionFactory): ()
	local loaded: boolean, reason: string? = ActionRegistry.Load({ factory }, {}, {})
	expect(loaded).toBe(true)
	expect(reason).toBeNil()
end

local function createController(): (Actor, any)
	local actor: Actor = ActorEntity.new()
	actor.enabled = true
	local controller: any = ActionControllerModule.new(actor)
	table.insert(controllers, controller)
	return actor, controller
end

local function heartbeat(elapsed: number): ()
	now += elapsed
	ActionControllerModule._heartbeatForTests(elapsed)
end

beforeEach(function()
	ActionRegistry._resetForTests()
	controllers = {}
	now = 100
	ActionControllerModule._setClockForTests(function(): number
		return now
	end)
	ActionControllerModule._setAutomaticSteppingEnabledForTests(false)
end)

afterEach(function()
	for _, controller: any in controllers do
		controller:Destroy()
	end
	ActionControllerModule._setClockForTests(nil)
	ActionControllerModule._setAutomaticSteppingEnabledForTests(true)
	ActionRegistry._resetForTests()
end)

it("never schedules an Action whose activation has no onUpdate", function()
	local factory: ActionTypes.ActionFactory = function(): ActionDefinition
		return { id = "Action.Wait", visibility = "ServerOnly", autoGrant = true }
	end
	loadFactory(factory)
	local _actor: Actor, controller: any = createController()
	local result: any = controller:RequestAction("Action.Wait")
	expect(result.accepted).toBe(true)
	expect(ActionControllerModule._hasUpdateEligibleInstancesForTests()).toBe(false)
	heartbeat(1)
	expect((controller:EndAction(result.sequenceId))).toBe(true)
end)

it("captures each activation's callback and private state, including state set by onStart", function()
	local factoryCalls: number = 0
	local observations: { string } = {}
	local factory: ActionTypes.ActionFactory = function(): ActionDefinition
		factoryCalls += 1
		local privateCount: number = factoryCalls * 10
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onStart = function(_context: ActionExecutionContext): ()
				privateCount += 1
			end,
			onUpdate = function(context: ActionExecutionContext, _deltaTime: number): ()
				table.insert(observations, tostring(context.sequenceId) .. ":" .. tostring(privateCount))
				privateCount += 1
			end,
		}
	end
	loadFactory(factory)
	local _actor: Actor, controller: any = createController()
	local first: any = controller:RequestAction("Action.Channel")
	local second: any = controller:RequestAction("Action.Channel")
	heartbeat(0.05)
	heartbeat(0.05)
	expect(observations).toEqual({ "1:21", "2:31", "1:22", "2:32" })
	expect((controller:EndAction(first.sequenceId))).toBe(true)
	expect((controller:EndAction(second.sequenceId))).toBe(true)
end)

it("keeps the captured callback when the factory's returned table changes later", function()
	local source: ActionDefinition? = nil
	local firstCalls: number = 0
	local replacementCalls: number = 0
	local factory: ActionTypes.ActionFactory = function(): ActionDefinition
		local definition: ActionDefinition = {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(): ()
				firstCalls += 1
			end,
		}
		source = definition
		return definition
	end
	loadFactory(factory)
	local _actor: Actor, controller: any = createController()
	local result: any = controller:RequestAction("Action.Channel")
	local capturedSource: ActionDefinition = source :: ActionDefinition
	capturedSource.onUpdate = function(): ()
		replacementCalls += 1
	end
	heartbeat(0.05)
	expect(firstCalls).toBe(1)
	expect(replacementCalls).toBe(0)
	expect((controller:EndAction(result.sequenceId))).toBe(true)
end)

it("waits at least 0.05 seconds and never catches up after a stall", function()
	local updates: { number } = {}
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(_context: ActionExecutionContext, deltaTime: number): ()
				table.insert(updates, deltaTime)
			end,
		}
	end)
	local _actor: Actor, controller: any = createController()
	local result: any = controller:RequestAction("Action.Channel")
	heartbeat(0.02)
	heartbeat(0.02)
	expect(updates).toEqual({})
	heartbeat(0.02)
	expect(#updates).toBe(1)
	expect(math.abs(updates[1] - 0.06) < 0.000001).toBe(true)
	heartbeat(0.18)
	expect(#updates).toBe(2)
	expect(math.abs(updates[2] - 0.18) < 0.000001).toBe(true)
	expect((controller:EndAction(result.sequenceId))).toBe(true)
end)

it("measures the first delta from activation and later deltas from the previous dispatch", function()
	local deltas: { number } = {}
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(context: ActionExecutionContext, deltaTime: number): ()
				if context.sequenceId == 2 then
					table.insert(deltas, deltaTime)
				end
			end,
		}
	end)
	local _actor: Actor, controller: any = createController()
	local first: any = controller:RequestAction("Action.Channel")
	heartbeat(0.03)
	local result: any = controller:RequestAction("Action.Channel")
	heartbeat(0.03)
	expect(#deltas).toBe(1)
	expect(math.abs(deltas[1] - 0.03) < 0.000001).toBe(true)
	heartbeat(0.2)
	expect(math.abs(deltas[2] - 0.2) < 0.000001).toBe(true)
	expect((controller:EndAction(first.sequenceId))).toBe(true)
	expect((controller:EndAction(result.sequenceId))).toBe(true)
end)

it("samples each instance's time immediately before its callback", function()
	local deltas: { number } = {}
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(context: ActionExecutionContext, deltaTime: number): ()
				table.insert(deltas, deltaTime)
				if context.sequenceId == 1 then
					now += 0.02
				end
			end,
		}
	end)
	local _actor: Actor, controller: any = createController()
	local first: any = controller:RequestAction("Action.Channel")
	local second: any = controller:RequestAction("Action.Channel")
	heartbeat(0.05)
	expect(#deltas).toBe(2)
	expect(math.abs(deltas[1] - 0.05) < 0.000001).toBe(true)
	expect(math.abs(deltas[2] - 0.07) < 0.000001).toBe(true)
	expect((controller:EndAction(first.sequenceId))).toBe(true)
	expect((controller:EndAction(second.sequenceId))).toBe(true)
end)

it("does not dispatch an update with a zero or non-finite measured delta", function()
	local deltas: { number } = {}
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(_context: ActionExecutionContext, deltaTime: number): ()
				table.insert(deltas, deltaTime)
			end,
		}
	end)
	local _actor: Actor, controller: any = createController()
	local result: any = controller:RequestAction("Action.Channel")
	ActionControllerModule._heartbeatForTests(0.05)
	expect(deltas).toEqual({})
	now = math.huge
	ActionControllerModule._heartbeatForTests(0.05)
	expect(deltas).toEqual({})
	now = 100.1
	ActionControllerModule._heartbeatForTests(0.05)
	expect(#deltas).toBe(1)
	expect(math.abs(deltas[1] - 0.1) < 0.000001).toBe(true)
	expect((controller:EndAction(result.sequenceId))).toBe(true)
end)

it("skips an Action ended before its turn and defers a reentrant start", function()
	local seen: { number } = {}
	local controller: any = nil
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(context: ActionExecutionContext, _deltaTime: number): ()
				table.insert(seen, context.sequenceId)
				if context.sequenceId == 1 then
					controller:EndAction(2)
					controller:RequestAction("Action.Channel")
				end
			end,
		}
	end)
	local _actor: Actor
	_actor, controller = createController()
	controller:RequestAction("Action.Channel")
	controller:RequestAction("Action.Channel")
	heartbeat(0.05)
	expect(seen).toEqual({ 1 })
	heartbeat(0.05)
	expect(seen).toEqual({ 1, 1, 3 })
end)

it("takes a global snapshot before an Actor can start an Action on another Actor", function()
	local seen: { string } = {}
	local sourceActor: Actor? = nil
	local sourceController: any = nil
	local targetController: any = nil
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(context: ActionExecutionContext, _deltaTime: number): ()
				table.insert(seen, if context.actor == sourceActor then "source" else "target")
				if context.sequenceId == 1 and context.actor == sourceActor then
					targetController:RequestAction("Action.Channel")
				elseif context.sequenceId == 1 then
					sourceController:RequestAction("Action.Channel")
				end
			end,
		}
	end)
	sourceActor, sourceController = createController()
	local _targetActor: Actor
	_targetActor, targetController = createController()
	sourceController:RequestAction("Action.Channel")
	targetController:RequestAction("Action.Channel")
	heartbeat(0.05)
	table.sort(seen)
	expect(seen).toEqual({ "source", "target" })
	heartbeat(0.05)
	expect(#seen).toBe(6)
end)

it("skips a captured Actor group destroyed by another Actor's update", function()
	local seen: { string } = {}
	local sourceActor: Actor? = nil
	local sourceController: any = nil
	local targetController: any = nil
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(context: ActionExecutionContext, _deltaTime: number): ()
				if context.actor == sourceActor then
					table.insert(seen, "source")
					targetController:Destroy()
				else
					table.insert(seen, "target")
					sourceController:Destroy()
				end
			end,
		}
	end)
	sourceActor, sourceController = createController()
	local _targetActor: Actor
	_targetActor, targetController = createController()
	sourceController:RequestAction("Action.Channel")
	targetController:RequestAction("Action.Channel")
	heartbeat(0.05)
	expect(#seen).toBe(1)
	expect(ActionControllerModule._hasUpdateEligibleInstancesForTests()).toBe(true)
end)

it("never uses the catalog callback when an activation omits onUpdate", function()
	local factoryCalls: number = 0
	local catalogCalls: number = 0
	local factory: ActionTypes.ActionFactory = function(): ActionDefinition
		factoryCalls += 1
		if factoryCalls == 1 then
			return {
				id = "Action.Channel",
				visibility = "ServerOnly",
				autoGrant = true,
				onUpdate = function(): ()
					catalogCalls += 1
				end,
			}
		end
		return { id = "Action.Channel", visibility = "ServerOnly", autoGrant = true }
	end
	loadFactory(factory)
	local _actor: Actor, controller: any = createController()
	local result: any = controller:RequestAction("Action.Channel")
	expect(result.accepted).toBe(true)
	expect(ActionControllerModule._hasUpdateEligibleInstancesForTests()).toBe(false)
	heartbeat(0.2)
	expect(catalogCalls).toBe(0)
end)

it("allows self-End and self-Interrupt without updating those instances again", function()
	local counts: { [number]: number } = {}
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(context: ActionExecutionContext, _deltaTime: number): ()
				counts[context.sequenceId] = (counts[context.sequenceId] or 0) + 1
				if context.sequenceId == 1 then
					context:End()
				else
					context:Interrupt("Manual")
				end
			end,
		}
	end)
	local _actor: Actor, controller: any = createController()
	local first: any = controller:RequestAction("Action.Channel")
	local second: any = controller:RequestAction("Action.Channel")
	heartbeat(0.05)
	heartbeat(0.05)
	expect(counts).toEqual({ [1] = 1, [2] = 1 })
	expect((controller:EndAction(first.sequenceId))).toBe(false)
	expect((controller:EndAction(second.sequenceId))).toBe(false)
	expect(ActionControllerModule._hasUpdateEligibleInstancesForTests()).toBe(false)
end)

it("interrupts a thrown update once and continues with the next instance", function()
	local reasons: { string } = {}
	local updatedSecond: number = 0
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(context: ActionExecutionContext, _deltaTime: number): ()
				if context.sequenceId == 1 then
					error("update boom")
				end
				updatedSecond += 1
			end,
			onInterrupt = function(_context: ActionExecutionContext, reason: string): ()
				table.insert(reasons, reason)
			end,
		}
	end)
	local _actor: Actor, controller: any = createController()
	local first: any = controller:RequestAction("Action.Channel")
	local second: any = controller:RequestAction("Action.Channel")
	heartbeat(0.05)
	expect(reasons).toEqual({ "ActionUpdateFailed" })
	expect(updatedSecond).toBe(1)
	expect((controller:EndAction(first.sequenceId))).toBe(false)
	expect((controller:EndAction(second.sequenceId))).toBe(true)
end)

it("retires a yielding update and interrupts its Action exactly once", function()
	local resumed: boolean = false
	local reasons: { string } = {}
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(_context: ActionExecutionContext, _deltaTime: number): ()
				task.wait()
				resumed = true
			end,
			onInterrupt = function(_context: ActionExecutionContext, reason: string): ()
				table.insert(reasons, reason)
			end,
		}
	end)
	local _actor: Actor, controller: any = createController()
	local result: any = controller:RequestAction("Action.Channel")
	heartbeat(0.05)
	task.wait()
	task.wait()
	expect(reasons).toEqual({ "ActionUpdateFailed" })
	expect(resumed).toBe(false)
	expect((controller:EndAction(result.sequenceId))).toBe(false)
end)

it("does not interrupt again if an update ends its Action before throwing", function()
	local ended: number = 0
	local interrupted: number = 0
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(context: ActionExecutionContext, _deltaTime: number): ()
				context:End()
				error("late update boom")
			end,
			onEnd = function(): ()
				ended += 1
			end,
			onInterrupt = function(): ()
				interrupted += 1
			end,
		}
	end)
	local _actor: Actor, controller: any = createController()
	controller:RequestAction("Action.Channel")
	heartbeat(0.05)
	expect(ended).toBe(1)
	expect(interrupted).toBe(0)
end)

it("updates membership before start and terminal hooks run", function()
	local observations: { boolean } = {}
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(): () end,
			onStart = function(): ()
				table.insert(observations, ActionControllerModule._hasUpdateEligibleInstancesForTests())
			end,
			onEnd = function(): ()
				table.insert(observations, ActionControllerModule._hasUpdateEligibleInstancesForTests())
			end,
			onInterrupt = function(): ()
				table.insert(observations, ActionControllerModule._hasUpdateEligibleInstancesForTests())
			end,
		}
	end)
	local _actor: Actor, controller: any = createController()
	local first: any = controller:RequestAction("Action.Channel")
	controller:EndAction(first.sequenceId)
	local second: any = controller:RequestAction("Action.Channel")
	controller:InterruptAction(second.sequenceId, "Manual")
	expect(observations).toEqual({ true, false, true, false })
end)

it("skips an Action interrupted before its snapshot turn", function()
	local seen: { number } = {}
	local controller: any = nil
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(context: ActionExecutionContext, _deltaTime: number): ()
				table.insert(seen, context.sequenceId)
				if context.sequenceId == 1 then
					controller:InterruptAction(2, "Manual")
				end
			end,
		}
	end)
	local _actor: Actor
	_actor, controller = createController()
	controller:RequestAction("Action.Channel")
	controller:RequestAction("Action.Channel")
	heartbeat(0.05)
	expect(seen).toEqual({ 1 })
	expect(ActionControllerModule._hasUpdateEligibleInstancesForTests()).toBe(true)
end)

it("removes every update-enabled Action before destruction hooks run", function()
	local eligibleDuringTeardown: { boolean } = {}
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(): () end,
			onInterrupt = function(): ()
				table.insert(eligibleDuringTeardown, ActionControllerModule._hasUpdateEligibleInstancesForTests())
			end,
		}
	end)
	local _actor: Actor, controller: any = createController()
	controller:RequestAction("Action.Channel")
	controller:RequestAction("Action.Channel")
	controller:Destroy()
	expect(eligibleDuringTeardown).toEqual({ false, false })
	expect(ActionControllerModule._hasUpdateEligibleInstancesForTests()).toBe(false)
	heartbeat(0.05)
end)

it("keeps one scheduler until the last update-enabled Action leaves and reconnects cleanly", function()
	local calls: number = 0
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(): ()
				calls += 1
			end,
		}
	end)
	local _firstActor: Actor, firstController: any = createController()
	local _secondActor: Actor, secondController: any = createController()
	ActionControllerModule._setAutomaticSteppingEnabledForTests(true)
	local first: any = firstController:RequestAction("Action.Channel")
	local second: any = secondController:RequestAction("Action.Channel")
	expect(ActionControllerModule._isSchedulerConnectedForTests()).toBe(true)
	heartbeat(0.03)
	firstController:EndAction(first.sequenceId)
	expect(ActionControllerModule._isSchedulerConnectedForTests()).toBe(true)
	secondController:Destroy()
	expect(ActionControllerModule._isSchedulerConnectedForTests()).toBe(false)
	local third: any = firstController:RequestAction("Action.Channel")
	heartbeat(0.02)
	expect(calls).toBe(0)
	heartbeat(0.03)
	expect(calls).toBe(1)
	expect((firstController:EndAction(third.sequenceId))).toBe(true)
	expect((secondController:EndAction(second.sequenceId))).toBe(false)
end)

it("automatically dispatches updates from Heartbeat while an eligible Action is active", function()
	local deltas: { number } = {}
	loadFactory(function(): ActionDefinition
		return {
			id = "Action.Channel",
			visibility = "ServerOnly",
			autoGrant = true,
			onUpdate = function(_context: ActionExecutionContext, deltaTime: number): ()
				table.insert(deltas, deltaTime)
			end,
		}
	end)
	ActionControllerModule._setClockForTests(nil)
	ActionControllerModule._setAutomaticSteppingEnabledForTests(true)
	local _actor: Actor, controller: any = createController()
	local result: any = controller:RequestAction("Action.Channel")
	for _attempt: number = 1, 30 do
		if #deltas > 0 then
			break
		end
		task.wait()
	end
	expect(#deltas > 0).toBe(true)
	expect(math.isfinite(deltas[1]) and deltas[1] > 0).toBe(true)
	expect((controller:EndAction(result.sequenceId))).toBe(true)
	expect(ActionControllerModule._isSchedulerConnectedForTests()).toBe(false)
end)
