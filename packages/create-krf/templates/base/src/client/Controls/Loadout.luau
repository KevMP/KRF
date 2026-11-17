--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local KRF = require(ReplicatedStorage.Packages.KRF)

local Loadout = {}

local SLOTS: { string } = { "AbilitySlot1" }

local equipped: { [string]: string } = {
	AbilitySlot1 = "Focus",
}

function Loadout.Equip(slot: string, actionId: string?): ()
	assert(table.find(SLOTS, slot) ~= nil, `{slot} is not an ability slot`)
	equipped[slot] = actionId
end

function Loadout.GetEquipped(slot: string): string?
	return equipped[slot]
end

function Loadout.Profile(): KRF.ControlProfile
	local profile: KRF.ControlProfile = { routes = {} }

	for _, slot: string in SLOTS do
		profile.routes[#profile.routes + 1] = {
			when = { kind = "Input", inputId = slot, gesture = "Pressed" },
			target = {
				kind = "Dynamic",
				resolve = function(): KRF.ResolvedAction?
					local actionId: string? = equipped[slot]

					return if actionId ~= nil then { actionId = actionId } else nil
				end,
			},
		}
	end

	return profile
end

return Loadout
