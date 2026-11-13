--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local InputTypes = require(KRF.client.Input.types)
local ActionTypes = require(KRF.client.Action.types)

local inputs: { [string]: InputTypes.InputDefinition } = {}

local keys: { [string]: Enum.KeyCode } =
	{ F = Enum.KeyCode.F, Q = Enum.KeyCode.Q, X = Enum.KeyCode.X, Z = Enum.KeyCode.Z }

for id: string, key: Enum.KeyCode in keys do
	inputs[id] = {
		context = "FireDemo",
		type = Enum.InputActionType.Bool,
		bindings = { Keyboard = { keyCode = key } },
	}
end

local source: InputTypes.InputSourceDefinition = {
	contexts = { FireDemo = { priority = 2000, sink = true } },
	inputs = inputs,
	sequenceGroups = {
		FireSpells = {
			policy = "DeferredPrefix",
			maxGapSeconds = 0.6,
			maxTotalSeconds = 1.5,
			scope = { "X", "Q", "Z" },
		},
	},
	sequences = {
		FireballPrefix = { steps = { "X", "Q" }, exclusiveGroup = "FireSpells" },
		FlameStrike = { steps = { "X", "Q", "Z" }, exclusiveGroup = "FireSpells" },
		-- An immediate exclusive match reserves Q's own press while the group
		-- decides between its completed short prefix and the longer spell.
		ReserveComboQ = { steps = { "X", "Q" }, maxGapSeconds = 0.6, maxTotalSeconds = 1.5, scope = { "X", "Q", "Z" } },
	},
}

local profile: ActionTypes.ControlProfile = {
	routes = {
		{
			when = { kind = "Input", inputId = "F", gesture = "Pressed" },
			target = { kind = "Fixed", actionId = "Demo.FireBreath" },
		},
		{
			when = { kind = "Input", inputId = "Q", gesture = "Pressed" },
			target = { kind = "Fixed", actionId = "Demo.Fireball" },
		},
		{
			when = { kind = "Sequence", sequenceId = "ReserveComboQ" },
			target = {
				kind = "Dynamic",
				-- Reservation intentionally selects no Action. Exclusive dispatch
				-- masks the same occurrence's raw Q route before resolving this.
				resolve = function(): ActionTypes.ResolvedAction?
					return nil
				end,
			},
			dispatch = { mode = "Exclusive" },
		},
		{
			when = { kind = "Sequence", sequenceId = "FireballPrefix" },
			target = { kind = "Fixed", actionId = "Demo.Fireball" },
		},
		{
			when = { kind = "Sequence", sequenceId = "FlameStrike" },
			target = { kind = "Fixed", actionId = "Demo.FlameStrike" },
		},
	},
}

local policies: ActionTypes.ActionInputPolicies = {
	["Demo.FireBreath"] = { activation = "WhileDown" },
	["Demo.Fireball"] = { activation = "OneShot" },
	["Demo.FlameStrike"] = { activation = "OneShot" },
}

return { Source = source, Profile = profile, Policies = policies }
