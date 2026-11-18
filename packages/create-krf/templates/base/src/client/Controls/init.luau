--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)
local Keybinds = require(script.Keybinds)
local Loadout = require(script.Loadout)
local LocalCharacter = require(script.Parent.LocalCharacter)

local Controls = {}

local function control(view: KRF.ActorView): ()
	assert(KRF.ClientControls.Apply({
		profiles = { { kind = "Set", actor = view, sourceId = "Loadout", profile = Loadout.Profile() } },
		selection = { kind = "Set", actor = view },
	}))
end

function Controls.Start(): ()
	assert(KRF.ClientControls.Apply(Keybinds))
	LocalCharacter.Observe(control)
end

return Controls
