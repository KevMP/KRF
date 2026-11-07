--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.client.Action.types)
local InputTypes = require(KRF.client.Input.types)
local Examples = {}

function Examples.Inputs(button: GuiButton?): InputTypes.InputSourceDefinition
	local bindings: { [string]: InputTypes.BindingDefinition } = {
		Keyboard = { keyCode = Enum.KeyCode.F },
		Mouse = { keyCode = Enum.KeyCode.MouseLeftButton },
		Gamepad = { keyCode = Enum.KeyCode.ButtonR2 },
	}

	if button ~= nil then
		bindings.Touch = { uiButton = button }
	end

	return {
		contexts = { Combat = { priority = 2000, sink = true }, Signs = { priority = 1000, sink = false } },
		inputs = {
			Primary = { context = "Combat", type = Enum.InputActionType.Bool, bindings = bindings },
			Ability1 = {
				context = "Combat",
				type = Enum.InputActionType.Bool,
				bindings = { Keyboard = { keyCode = Enum.KeyCode.E } },
			},
			X = {
				context = "Signs",
				type = Enum.InputActionType.Bool,
				bindings = { Keyboard = { keyCode = Enum.KeyCode.X } },
			},
			Q = {
				context = "Signs",
				type = Enum.InputActionType.Bool,
				bindings = { Keyboard = { keyCode = Enum.KeyCode.Q } },
			},
			Z = {
				context = "Signs",
				type = Enum.InputActionType.Bool,
				bindings = { Keyboard = { keyCode = Enum.KeyCode.Z } },
			},
		},
		sequences = { Fireball = { steps = { "X", "Q", "Z" }, maxGapSeconds = 0.5, maxTotalSeconds = 2 } },
	}
end

function Examples.Base(resolve: (Types.RouteResolveContext) -> Types.ResolvedAction?): Types.ControlProfile
	-- IAS context priority, source priority and dispatch priority govern separate
	-- decisions. The resolved concrete Action's I6 policy owns activation.
	return {
		routes = {
			{
				when = { kind = "Input", inputId = "Primary", gesture = "Pressed" },
				target = { kind = "Fixed", actionId = "Combat.Punch" },
			},
			{
				when = { kind = "Input", inputId = "Q", gesture = "Pressed" },
				target = { kind = "Fixed", actionId = "Movement.Dash" },
			},
			{
				when = { kind = "Input", inputId = "Z", gesture = "Pressed" },
				target = { kind = "Fixed", actionId = "Sign.Z" },
			},
			{
				when = { kind = "Input", inputId = "Ability1", gesture = "Pressed" },
				target = { kind = "Dynamic", resolve = resolve },
			},
		},
	}
end

function Examples.Sword(): Types.ControlProfile
	return {
		priority = 100,
		routes = {
			{
				when = { kind = "Input", inputId = "Primary", gesture = "Pressed" },
				target = { kind = "Fixed", actionId = "Combat.SwordSlash" },
			},
		},
	}
end

function Examples.Fireball(independent: boolean?): Types.ControlProfile
	return {
		routes = {
			{
				when = { kind = "Sequence", sequenceId = "Fireball" },
				target = { kind = "Fixed", actionId = "Technique.Fireball" },
				-- Immediate Exclusive masks final Z; Deferred never masks an old key.
				dispatch = if independent then { mode = "Independent" } else nil,
			},
		},
	}
end

return Examples
