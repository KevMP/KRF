--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect = JestGlobals.expect
local Types = require(KRF.client.Controls.types)
local InputTypes = require(KRF.client.Input.types)
local ActionTypes = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local Controls: Types.ClientControls = require(KRF.client.Controls.ClientControls)
local Runtime: ActionTypes.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local Lifecycle = require(KRF.client.Controls.utils.NativeControlLifecycle)
local ActionUtils = require(script.Parent.ActionInputTestUtils)

export type Fixture = {
	base: ActionUtils.Fixture,
	writes: { string },
	failAt: { [number]: boolean },
	onWrite: ((string) -> ())?,
	events: { InputTypes.SemanticInputEvent },
	lifecycle: { (Types.ControlLifecycleEvent) -> () },
	connections: number,
	stopCalls: number,
	restore: () -> (),
}

local Utils = {}

function Utils.new(): Fixture
	local originalObserve: typeof(Lifecycle.Observe) = Lifecycle.Observe

	local fixture: Fixture = {
		base = ActionUtils.new(),
		writes = {},
		failAt = {},
		events = {},
		lifecycle = {},
		connections = 0,
		stopCalls = 0,
		restore = function(): ()
			Lifecycle.Observe = originalObserve
		end,
	}

	Lifecycle.Observe = function(
		callback: (Types.ControlLifecycleEvent) -> (),
		_signals: Types.ControlLifecycleSignals?
	): () -> ()
		table.insert(fixture.lifecycle, callback)
		fixture.connections += 1

		local active: boolean = true

		return function(): ()
			if active then
				active = false
				fixture.connections -= 1
			end
		end
	end

	fixture.base.configureNative = function(native: InputTypes.NativeInputAdapter): ()
		local function write(operation: string): ()
			table.insert(fixture.writes, operation)

			if fixture.failAt[#fixture.writes] then
				error("InjectedNativeFault", 0)
			end

			if fixture.onWrite ~= nil then
				fixture.onWrite(operation)
			end
		end

		local createContext = native.CreateContext
		local configureContext = native.ConfigureContext
		local createAction = native.CreateAction
		local createBinding = native.CreateBinding
		local destroy = native.Destroy

		native.CreateContext = function(id: string, definition: InputTypes.ContextDefinition): InputContext
			write("CreateContext:" .. id)

			return createContext(id, definition)
		end

		native.ConfigureContext = function(
			context: InputContext,
			definition: InputTypes.ContextDefinition,
			enabled: boolean
		): ()
			write("ConfigureContext:" .. context.Name)
			configureContext(context, definition, enabled)
		end

		native.CreateAction = function(
			id: string,
			definition: InputTypes.InputDefinition,
			context: InputContext
		): InputAction
			write("CreateAction:" .. id)

			return createAction(id, definition, context)
		end

		native.CreateBinding = function(
			slot: string,
			definition: InputTypes.BindingDefinition,
			action: InputAction
		): InputBinding
			write("CreateBinding:" .. action.Name .. ":" .. slot)

			return createBinding(slot, definition, action)
		end

		native.Destroy = function(instance: Instance): ()
			write("Destroy:" .. instance.Name)
			destroy(instance)
		end
	end

	return fixture
end

function Utils.ready(fixture: Fixture, policies: ActionTypes.ActionInputPolicies?): ()
	local effective: ActionTypes.ActionInputPolicies = policies or ActionUtils.policies()

	if policies == nil then
		effective["Combat.Rasengan"].stopParameters = function(): { releaseAim: number }
			fixture.stopCalls += 1

			return { releaseAim = 2 }
		end
	end

	ActionUtils.ready(fixture.base, effective)

	fixture.base.input.ObservePrimitive("Routing", function(occurrence: InputTypes.PrimitiveOccurrence): ()
		table.insert(fixture.events, occurrence.event)
	end)

	fixture.base.restore()
end

function Utils.apply(changeSet: Types.ControlChangeSet): ()
	expect({ Controls.Apply(changeSet) }).toEqual({ true })
end

function Utils.charge(fixture: Fixture): number
	ActionUtils.set(fixture.base, { ActionUtils.route("Combat.Rasengan") })
	ActionUtils.emit(fixture.base, "Pressed")

	return ActionUtils.started(fixture.base)
end

function Utils.manual(): InputTypes.InputSourceDefinition
	return {
		contexts = { HandSigns = { priority = 3000, sink = true } },
		inputs = {
			Sign = {
				context = "HandSigns",
				type = Enum.InputActionType.Bool,
				bindings = {
					Keyboard = { keyCode = Enum.KeyCode.Q },
					Gamepad = { keyCode = Enum.KeyCode.ButtonR2 },
				},
			},
		},
		gestures = { Sign = { Held = { afterSeconds = 0.25 } } },
		sequences = { Combo = { steps = { "X", "Sign" }, maxGapSeconds = 1, maxTotalSeconds = 2 } },
	}
end

function Utils.install(fixture: Fixture): ()
	Utils.apply({
		inputs = { { kind = "Set", sourceId = "Manual", definition = Utils.manual() } },
		profiles = {
			{
				kind = "Set",
				actor = fixture.base.actor,
				sourceId = "Manual",
				profile = {
					routes = { ActionUtils.route("Combat.Fireball", { kind = "Sequence", sequenceId = "Combo" }) },
				},
			},
		},
		contexts = { { contextId = "HandSigns", enabled = true } },
	})
end

function Utils.route(fixture: Fixture, actor: ActorTypes.ActorView?): ActionTypes.RouteQuerySnapshot
	return assert(Runtime.GetEffectiveRoute(actor or fixture.base.actor, ActionUtils.key()))
end

function Utils.loss(fixture: Fixture, event: Types.ControlLifecycleEvent): ()
	expect(#fixture.lifecycle).toBe(1)

	for _, callback in fixture.lifecycle do
		callback(event)
	end
end

function Utils.kinds(fixture: Fixture): { string }
	local kinds: { string } = {}

	for _, packet in ActionUtils.packets(fixture.base) do
		table.insert(kinds, packet.kind)
	end

	return kinds
end

function Utils.destroy(fixture: Fixture?): ()
	if fixture ~= nil then
		fixture.onWrite = nil
		fixture.base.commands.beforeSend = nil
		fixture.restore()
		ActionUtils.destroy(fixture.base)
	end
end

return Utils
