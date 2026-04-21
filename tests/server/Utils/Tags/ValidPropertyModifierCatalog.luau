return {
	{
		id = "Status.Stunned",
		duplicateBehavior = "Refresh",
		visibility = "ClientVisible",
		properties = {
			WalkSpeed = {
				set = 0,
			},
		},
	},

	{
		id = "Buff.Sprint",
		duplicateBehavior = "Stack",
		maxStacks = 3,
		visibility = "ClientVisible",
		properties = {
			WalkSpeed = {
				add = 6,
				multiply = 1.15,
				min = 0,
				max = 32,
			},
		},
	},
}
