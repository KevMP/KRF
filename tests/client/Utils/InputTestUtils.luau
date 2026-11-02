--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local Types = require(KRF.client.Input.types)
local Owner = require(KRF.client.Input.InputOwner)
local Native = require(KRF.client.Input.utils.NativeInputAdapter)

export type Fixture = {
	owner: Types.InputOwner,
	native: Types.NativeInputAdapter,
	container: Folder,
	contexts: { [string]: InputContext },
	actions: { [string]: InputAction },
	bindings: { [string]: InputBinding },
	callbacks: { [InputAction]: (Types.NativeTransition, any) -> () },
	states: { [InputAction]: any },
	events: { Types.SemanticInputEvent },
	faults: { string },
	writes: { string },
	connections: number,
	containerDestroyCalls: number,
	now: number,
	ready: boolean,
	failAt: { [number]: boolean },
	onWrite: ((string) -> ())?,
	syntheticEnd: boolean,
	onPublish: ((Types.SemanticInputEvent) -> ())?,
}

local TestUtils = {}

export type CoreDefinition = {
	contexts: { [string]: Types.ContextDefinition },
	inputs: { [string]: Types.InputDefinition },
}

function TestUtils.definition(inputType: Enum.InputActionType?): CoreDefinition
	return {
		contexts = { Gameplay = { priority = 2000, sink = true } },
		inputs = {
			Primary = {
				context = "Gameplay",
				type = inputType or Enum.InputActionType.Bool,
				bindings = {
					Keyboard = { keyCode = Enum.KeyCode.Q },
					Gamepad = { keyCode = Enum.KeyCode.ButtonR2 },
				},
			},
		},
	}
end

function TestUtils.new(): Fixture
	local fixture: Fixture = {
		owner = {} :: Types.InputOwner,
		native = {} :: Types.NativeInputAdapter,
		container = Instance.new("Folder"),
		contexts = {},
		actions = {},
		bindings = {},
		callbacks = {},
		states = {},
		events = {},
		faults = {},
		writes = {},
		connections = 0,
		containerDestroyCalls = 0,
		now = 10,
		ready = true,
		failAt = {},
		syntheticEnd = false,
	}

	local native: Types.NativeInputAdapter = Native.new()

	local function write(operation: string): ()
		table.insert(fixture.writes, operation)

		if fixture.failAt[#fixture.writes] then
			error("InjectedNativeFault", 0)
		end

		if fixture.onWrite ~= nil then
			fixture.onWrite(operation)
		end
	end

	fixture.native = {
		CreateContext = function(id: string, definition: Types.ContextDefinition): InputContext
			write("CreateContext:" .. id)

			local context: InputContext = Instance.new("InputContext")
			context.Name = id
			context.Enabled = false
			context.Priority = definition.priority
			context.Sink = definition.sink
			context.Parent = fixture.container
			fixture.contexts[id] = context

			return context
		end,
		ConfigureContext = function(context: InputContext, definition: Types.ContextDefinition, enabled: boolean): ()
			write("ConfigureContext:" .. context.Name)

			if not enabled and fixture.syntheticEnd then
				for action: InputAction, callback in fixture.callbacks do
					if action.Parent == context then
						callback("Released", false)
					end
				end
			end

			native.ConfigureContext(context, definition, enabled)
		end,
		CreateAction = function(id: string, definition: Types.InputDefinition, context: InputContext): InputAction
			write("CreateAction:" .. id)
			local action: InputAction = native.CreateAction(id, definition, context)

			fixture.actions[id] = action

			fixture.states[action] = if definition.type == Enum.InputActionType.Bool
				then false
				else if definition.type == Enum.InputActionType.Direction1D
					then 0
					else if definition.type == Enum.InputActionType.Direction3D then Vector3.zero else Vector2.zero

			return action
		end,
		CreateBinding = function(slot: string, definition: Types.BindingDefinition, action: InputAction): InputBinding
			write("CreateBinding:" .. action.Name .. ":" .. slot)
			local binding: InputBinding = native.CreateBinding(slot, definition, action)

			fixture.bindings[action.Name .. ":" .. slot] = binding

			return binding
		end,
		ObserveAction = function(action: InputAction, callback: (Types.NativeTransition, any) -> ()): () -> ()
			fixture.callbacks[action] = callback
			fixture.connections += 1

			local active: boolean = true

			return function(): ()
				if active then
					active = false
					fixture.connections -= 1
					fixture.callbacks[action] = nil
				end
			end
		end,
		ReadState = function(action: InputAction): any
			return fixture.states[action]
		end,
		Destroy = function(instance: Instance): ()
			write("Destroy:" .. instance.Name)
			instance:Destroy()
		end,
		DestroyContainer = function(): ()
			fixture.containerDestroyCalls += 1
			fixture.container:Destroy()
		end,
	}

	fixture.owner = Owner.new({
		Native = fixture.native,
		Now = function(): number
			return fixture.now
		end,
		IsReady = function(): boolean
			return fixture.ready
		end,
		Publish = function(event: Types.SemanticInputEvent): ()
			table.insert(fixture.events, event)

			if fixture.onPublish ~= nil then
				fixture.onPublish(event)
			end
		end,
		ReportFault = function(reason: string): ()
			table.insert(fixture.faults, reason)
		end,
	})

	return fixture
end

function TestUtils.install(fixture: Fixture, definition: Types.InputSourceDefinition?): ()
	local success: boolean, reason: string? = fixture.owner.SetSource("Core", definition or TestUtils.definition())
	expect({ success, reason }).toEqual({ true })
end

function TestUtils.enable(fixture: Fixture): ()
	local success: boolean, reason: string? = fixture.owner.SetContextEnabled("Gameplay", true)
	expect({ success, reason }).toEqual({ true })
end

function TestUtils.emit(fixture: Fixture, kind: Types.NativeTransition, value: any, id: string?): ()
	local action: InputAction? = fixture.actions[id or "Primary"]
	assert(action ~= nil, "Expected installed native action")
	local callback = fixture.callbacks[action]
	assert(callback ~= nil, "Expected connected native observer")
	fixture.states[action] = value
	callback(kind, value)
end

function TestUtils.kinds(fixture: Fixture): { string }
	local kinds: { string } = {}

	for _, event: Types.SemanticInputEvent in fixture.events do
		table.insert(kinds, event.kind)
	end

	return kinds
end

function TestUtils.destroy(fixture: Fixture): ()
	fixture.owner.Destroy()
	fixture.container:Destroy()
end

return TestUtils
