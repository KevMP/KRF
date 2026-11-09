--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local Types = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local InputTypes = require(KRF.client.Input.types)
local RequestTypes = require(KRF.shared.ActionRequest.types)
local WireTypes = require(KRF.shared.Networking.types)
local ClientTypes = require(KRF.client.types)
local Client: ClientTypes.Client = require(KRF.client)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local InputOwner = require(KRF.client.Input.InputOwner)
local NativeInput = require(KRF.client.Input.utils.NativeInputAdapter)
local NativeNetworking = require(KRF.client.Networking.utils.NativeClientDependencies)
local InputState = require(KRF.client.Input.utils.InputRuntimeState)
local CommandCodec = require(KRF.shared.Networking.CommandCodec)
local Catalog = require(KRF.shared.ActionRequest.ActionRequestCatalog)
local PayloadCodec = require(KRF.shared.ActionRequest.utils.ActionPayloadCodec)
local Commands = require(script.Parent.CommandClientTestUtils)
local Requests = require(script.Parent.ActionRequestClientTestUtils)
local Clock = require(script.Parent.Parent.Parent.shared.Utils.TestClock)

local SharedSchemas: RequestTypes.ActionRequestSchemas =
	require(script.Parent.Parent.Parent.integration.ActionInput.Schemas)

-- Pending public I6 methods are deliberately asserted at the call site, so an
-- absent method is a missing-contract assertion rather than a nil-call error.
export type DirectRuntime = {
	RequestAction: (ActorTypes.ActorView, string, any?) -> (number?, string?),
	RequestStop: (number, any?) -> (number?, string?),
	RequestInterrupt: (number, RequestTypes.ActionInputInterruptReason) -> (number?, string?),
}

export type Packet = {
	kind: string,
	requestId: number,
	originalStartRequestId: number?,
	actionId: string?,
	parameters: any?,
	reason: string?,
}

export type Fixture = {
	commands: Commands.Fixture,
	clock: typeof(Clock.new()),
	input: InputTypes.InputOwner,
	configureNative: ((InputTypes.NativeInputAdapter) -> ())?,
	actor: ActorTypes.ActorView,
	other: ActorTypes.ActorView,
	actions: { [string]: InputAction },
	callbacks: { [InputAction]: (InputTypes.NativeTransition, any) -> () },
	states: { [InputAction]: any },
	schemas: RequestTypes.ActionRequestSchemas,
	container: Folder,
	syntheticEnd: boolean,
	inputTime: number?,
	restore: () -> (),
}

local Utils = {}

function Utils.schemas(): RequestTypes.ActionRequestSchemas
	local schemas: RequestTypes.ActionRequestSchemas = {}

	for actionId: string, entry: RequestTypes.ActionRequestSchema in SharedSchemas do
		schemas[actionId] = table.clone(entry)
	end

	return schemas
end

function Utils.policies(): Types.ActionInputPolicies
	return {
		["Combat.Rasengan"] = {
			activation = "WhileDown",
			startParameters = function(): any
				return { aim = 1 }
			end,
			stopParameters = function(): any
				return { releaseAim = 2 }
			end,
		},
		["Combat.Fireball"] = {
			startParameters = function(): any
				return { aim = 3 }
			end,
		},
		["Movement.Sprint"] = { activation = "WhileDown" },
		["Mode.Aura"] = { activation = "Toggle" },
	}
end

function Utils.new(): Fixture
	local commandFixture: Commands.Fixture = Commands.new()
	local clock = Clock.new(100)

	NativeNetworking.Now = clock.Now
	NativeNetworking.ScheduleTimeout = clock.Schedule

	local container: Folder = Instance.new("Folder")
	local originalNew: typeof(InputOwner.new) = InputOwner.new

	local fixture: Fixture = {
		commands = commandFixture,
		clock = clock,
		input = {} :: InputTypes.InputOwner,
		actor = {} :: ActorTypes.ActorView,
		other = {} :: ActorTypes.ActorView,
		actions = {},
		callbacks = {},
		states = {},
		schemas = Utils.schemas(),
		container = container,
		syntheticEnd = false,
		restore = function(): ()
			InputOwner.new = originalNew
		end,
	}

	-- Keep Client.Init, InstallConsumers, and all Input/I4/I5 owners intact.
	-- Only the native input boundary and clock are deterministic in unit tests.
	InputOwner.new = function(options: InputTypes.InputOwnerOptions): InputTypes.InputOwner
		local injected: InputTypes.InputOwnerOptions = table.clone(options)
		local native: InputTypes.NativeInputAdapter = NativeInput.new(container)
		local createAction = native.CreateAction
		local configureContext = native.ConfigureContext

		native.CreateAction = function(id, definition, context): InputAction
			local action: InputAction = createAction(id, definition, context)

			fixture.actions[id] = action
			fixture.states[action] = if definition.type == Enum.InputActionType.Bool then false else 0

			return action
		end

		native.ObserveAction = function(action, callback): () -> ()
			fixture.callbacks[action] = callback

			return function(): ()
				fixture.callbacks[action] = nil
			end
		end

		native.ReadState = function(action: InputAction): any
			return fixture.states[action]
		end

		native.ConfigureContext = function(context, definition, enabled): ()
			if fixture.syntheticEnd and not enabled then
				for action, callback in fixture.callbacks do
					if action.Parent == context then
						fixture.states[action] = false
						callback("Released", false)
					end
				end
			end

			configureContext(context, definition, enabled)
		end

		if fixture.configureNative ~= nil then
			fixture.configureNative(native)
		end

		injected.Native = native

		injected.Now = function(): number
			return fixture.inputTime or clock.Now()
		end

		injected.Scheduler = {
			Schedule = function(deadline: number, callback: () -> ()): () -> ()
				return clock.Schedule(math.max(0, deadline - clock.Now()), callback)
			end,
		}

		fixture.input = originalNew(injected)

		return fixture.input
	end

	return fixture
end

function Utils.ready(
	fixture: Fixture,
	policies: Types.ActionInputPolicies?,
	schemas: RequestTypes.ActionRequestSchemas?
): ()
	fixture.schemas = schemas or fixture.schemas

	Commands.ready(fixture.commands, {
		actionRequestSchemas = fixture.schemas,
		actionInputPolicies = policies,
	}, Requests.manifestCommands())

	fixture.restore()
	fixture.actor = Commands.baseline(fixture.commands)
	fixture.other = Commands.baseline(fixture.commands, 8, "ActorB")

	local inputs: { [string]: InputTypes.InputDefinition } = {}

	for _, id: string in { "AbilitySlot1", "Other", "X", "Q", "Z" } do
		inputs[id] = { context = "Combat", type = Enum.InputActionType.Bool, bindings = {} }
	end

	inputs.Axis = { context = "Combat", type = Enum.InputActionType.Direction1D, bindings = {} }

	expect({
		fixture.input.SetSource("Core", {
			contexts = { Combat = { priority = 2000, sink = true }, Gate = { priority = 1, sink = false } },
			inputs = inputs,
		}),
	}).toEqual({ true })

	expect({ fixture.input.SetContextEnabled("Combat", true) }).toEqual({ true })
	expect({ fixture.input.SetContextEnabled("Gate", true) }).toEqual({ true })
	expect({ Runtime.SetControlledActor(fixture.actor) }).toEqual({ true })
end

function Utils.key(inputId: string?, gesture: InputTypes.GestureKind?): Types.RouteKey
	return { kind = "Input", inputId = inputId or "AbilitySlot1", gesture = gesture or "Pressed" }
end

function Utils.route(actionId: string, key: Types.RouteKey?): Types.ActionRoute
	return { when = key or Utils.key(), target = { kind = "Fixed", actionId = actionId } }
end

function Utils.set(fixture: Fixture, routes: { Types.ActionRoute }, actor: ActorTypes.ActorView?): ()
	expect({ Runtime.SetProfileSource(actor or fixture.actor, "Base", { routes = routes }) }).toEqual({ true })
end

function Utils.emit(fixture: Fixture, kind: InputTypes.NativeTransition, inputId: string?, value: any?): ()
	local action: InputAction = assert(fixture.actions[inputId or "AbilitySlot1"], "Expected installed input")
	local callback = assert(fixture.callbacks[action], "Expected live native observer")
	local resolved: any = if value ~= nil then value else kind == "Pressed"

	fixture.states[action] = resolved
	callback(kind, resolved)
end

function Utils.tap(fixture: Fixture, inputId: string?): ()
	Utils.emit(fixture, "Pressed", inputId)
	Utils.emit(fixture, "Released", inputId)
end

function Utils.packets(fixture: Fixture): { Packet }
	local protocol: WireTypes.ClientProtocol =
		assert(fixture.commands.protocol, "Expected the installed command protocol")

	local catalog: RequestTypes.ActionRequestCatalog = assert(Catalog.Compile(fixture.schemas))
	local codec = CommandCodec.Compile(protocol)
	local packets: { Packet } = {}
	local originals: { [number]: string } = {}

	for _, bytes: buffer in fixture.commands.sent do
		local decoded: WireTypes.CommandRequest = assert(codec.DecodeRequest(bytes), "Expected a command packet")
		local commandId: string? = nil

		for id: string, command: WireTypes.ClientCommand in protocol.commandsById or {} do
			if command.code == decoded.commandCode then
				commandId = id
			end
		end

		local request: any = decoded.request
		local packet: Packet = { kind = commandId or "Unknown", requestId = decoded.requestId }

		if commandId == "KRF.Action.Start" then
			packet.actionId = request.actionId
			originals[decoded.requestId] = request.actionId

			local valid: boolean, parameters: any =
				PayloadCodec.Decode(catalog.requestsById[request.actionId].start, request.payload)

			assert(valid, "Expected valid typed Start bytes")
			packet.parameters = parameters
		elseif commandId == "KRF.Action.Stop" or commandId == "KRF.Action.Interrupt" then
			packet.originalStartRequestId = request.originalStartRequestId
			packet.actionId = originals[request.originalStartRequestId]
			packet.reason = request.reason

			if commandId == "KRF.Action.Stop" then
				local actionId: string = assert(packet.actionId, "Stop must follow its original Start")

				local valid: boolean, parameters: any = PayloadCodec.Decode(
					assert(catalog.requestsById[actionId].stop, "Expected the original Stop schema"),
					request.payload
				)

				assert(valid, "Expected valid typed Stop bytes")
				packet.parameters = parameters
			end
		end

		table.insert(packets, packet)
	end

	return packets
end

function Utils.started(fixture: Fixture, actionId: string?): number
	local packet: Packet? = Utils.packets(fixture)[1]
	expect(packet ~= nil).toBe(true)
	expect(packet).toMatchObject({ kind = "KRF.Action.Start", actionId = actionId or "Combat.Rasengan" })
	assert(packet ~= nil, "Selected Action must admit Start on the same input stack")

	return packet.requestId
end

function Utils.outcome(
	fixture: Fixture,
	requestId: number,
	commandId: string,
	status: "Accepted" | "Rejected",
	reason: string?
): ()
	local protocol: WireTypes.ClientProtocol =
		assert(fixture.commands.protocol, "Expected the installed command protocol")

	local commands: { [string]: WireTypes.ClientCommand } =
		assert(protocol.commandsById, "Expected the command codebook")

	local payload: buffer = assert(CommandCodec.Compile(protocol).EncodeResult({
		commandCode = commands[commandId].code,
		requestId = requestId,
		status = status,
		reason = reason,
		result = if commandId == "KRF.Action.Start" and status == "Accepted" then { sequenceId = 7 } else nil,
	}))

	assert(fixture.commands.client.inbound, "Expected a live reliable receiver")(payload)
	-- The production receiver yields between results to preserve public event order.
	-- Let its queued delivery finish before the fixture injects another result.
	task.wait()
end

function Utils.direct(): DirectRuntime
	local facade: DirectRuntime = (Runtime :: unknown) :: DirectRuntime
	expect(type(facade.RequestAction)).toBe("function")
	expect(type(facade.RequestStop)).toBe("function")
	expect(type(facade.RequestInterrupt)).toBe("function")

	return facade
end

function Utils.destroy(fixture: Fixture?): ()
	if fixture == nil then
		return
	end

	fixture.restore()
	fixture.commands.cleanup()
	fixture.container:Destroy()
	expect(InputState.Get()).toBeNil()
	expect(Client._IsInitialized()).toBe(false)
end

return Utils
