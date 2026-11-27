--!strict
export type FireballRequirements = {
	requiredTags: { string },
	blockedTags: { string },
	resourceRequirements: { [string]: { min: number?, max: number?, minPercent: number?, maxPercent: number? } },
	costs: { [string]: number | { amount: number?, percent: number?, multiplierProperty: string? } },
}

local requirements: FireballRequirements = {
	requiredTags = { "Status.Grounded" },
	blockedTags = { "Status.Stunned" },
	resourceRequirements = { Mana = { min = 30 } },
	costs = { Mana = 20 },
}

return requirements
