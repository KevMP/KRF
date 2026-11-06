--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Packages.KRF.client.Input.types)

-- Source-owned semantic sequences and a bounded scalar-state sword recognizer.
-- Install these declarations through InputRuntime after client initialization.
local Examples = {}

function Examples.Inputs(): Types.InputSourceDefinition
	local inputs: { [string]: Types.InputDefinition } = {}

	local gamepad: { [string]: Enum.KeyCode } = {
		X = Enum.KeyCode.ButtonX,
		Q = Enum.KeyCode.ButtonA,
		Z = Enum.KeyCode.ButtonB,
		A = Enum.KeyCode.ButtonR1,
		C = Enum.KeyCode.ButtonL1,
	}

	local keys: { [string]: Enum.KeyCode } =
		{ X = Enum.KeyCode.X, Q = Enum.KeyCode.Q, Z = Enum.KeyCode.Z, A = Enum.KeyCode.A, C = Enum.KeyCode.C }

	for id: string, key: Enum.KeyCode in keys do
		inputs[id] = {
			context = "Signs",
			type = Enum.InputActionType.Bool,
			bindings = { Keyboard = { keyCode = key }, Gamepad = { keyCode = gamepad[id] } },
		}
	end

	inputs.Aim = {
		context = "Signs",
		type = Enum.InputActionType.Direction2D,
		bindings = { Gamepad = { keyCode = Enum.KeyCode.Thumbstick2 } },
	}

	return { contexts = { Signs = { priority = 3000, sink = true } }, inputs = inputs }
end

function Examples.Immediate(): Types.InputSourceDefinition
	return {
		sequences = {
			Fireball = { steps = { "X", "Q", "Z" }, maxGapSeconds = 0.5, maxTotalSeconds = 2 },
			Short = { steps = { "X", "Q" }, maxGapSeconds = 0.5, maxTotalSeconds = 2 },
		},
	}
end

function Examples.Deferred(): Types.InputSourceDefinition
	return {
		sequenceGroups = {
			Signs = {
				policy = "DeferredPrefix",
				maxGapSeconds = 0.5,
				maxTotalSeconds = 2,
				scope = { "X", "Q", "Z", "C" },
			},
		},
		sequences = {
			Short = { steps = { "X", "Q" }, exclusiveGroup = "Signs" },
			Fireball = { steps = { "X", "Q", "Z" }, exclusiveGroup = "Signs" },
		},
	}
end

function Examples.Sword(): Types.InputSourceDefinition
	return {
		recognizers = {
			SwipeRight = {
				inputs = { "Aim" },
				maxWindowSeconds = 0.6,
				onEvent = function(ctx: Types.RecognizerContext, event: Types.RecognizerEvent): Types.CustomMatch?
					if event.kind ~= "StateChanged" or typeof(event.value) ~= "Vector2" then
						return nil
					end

					local previous: Types.RecognitionScalar? = ctx:GetState("previousX")
					local direction: Vector2 = event.value
					local success: boolean, reason: string? = ctx:SetState("previousX", direction.X)
					assert(success, reason)

					if type(previous) == "number" and previous < -0.5 and direction.X > 0.5 then
						return { metadata = { direction = "Right" } }
					end

					return nil
				end,
			},
		},
	}
end

return Examples
