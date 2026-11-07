--!strict
-- Explicit budgets for the profile compiler and synchronous private dispatch.
return table.freeze({
	MAX_ACTORS = 128,
	MAX_SOURCES_PER_ACTOR = 32,
	MAX_ROUTES_PER_SOURCE = 256,
	MAX_REQUIRED_CONTEXTS = 16,
	MAX_REQUIRED_CONTEXT_DECLARATIONS = 64,
	MAX_INTENTS_PER_OCCURRENCE = 16,
	-- Each switch reserves an I1 epoch plan and recognition-reset plan.
	MAX_PREPARED_PLANS = 32,
	MAX_ID_BYTES = 128,
	MAX_PRIORITY = 2147483647,
})
