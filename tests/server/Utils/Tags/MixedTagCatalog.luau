return {
	{
		id = "Status.Stunned",
		defaultDuration = 1.5,
		duplicateBehavior = "Refresh",
		visibility = "ClientVisible",
		properties = {
			WalkSpeed = {
				set = 0,
			},
			JumpPower = {
				set = 0,
			},
		},
	},

	{
		id = "Buff.Sprint",
		defaultDuration = 6,
		duplicateBehavior = "Stack",
		maxStacks = 3,
		visibility = "ClientVisible",
		properties = {
			WalkSpeed = {
				add = 6,
				multiply = 1.15,
				max = 32,
			},
			DashCostMultiplier = {
				multiply = 0.8,
			},
		},
	},

	{
		id = "Status.OnFire",
		defaultDuration = 5,
		tickInterval = 1,
		duplicateBehavior = "Refresh",
		visibility = "ClientVisible",
		onTick = function(_actor): ()
			return
		end,
		properties = {
			HealingReceived = {
				multiply = 0.75,
			},
		},
	},

	{
		id = "Buff.Armored",
		duplicateBehavior = "Ignore",
		visibility = "ServerOnly",
		properties = {
			DamageTaken = {
				multiply = 0.85,
				min = 0,
			},
		},
	},
}
