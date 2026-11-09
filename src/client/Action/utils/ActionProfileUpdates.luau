--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local Validator = require(script.Parent.Parent.ActionProfileValidator)
local Identity = require(script.Parent.ActionRouteIdentity)
local Graph = require(script.Parent.ActionProfileGraph)
local Limits = require(script.Parent.ActionRouteLimits)
local Updates = {}

-- Both ordinary replacement and future compound preflight use this compiler.
-- No resolver or observer is invoked and no installed state is mutated.
function Updates.Prepare(
	current: Graph.Catalog,
	updates: { Types.ProfileUpdate },
	input: InputTypes.InputGraphSnapshot,
	version: number,
	validateActor: (ActorTypes.ActorView?) -> string?
): (Graph.Catalog?, string?)
	if not Validator.IsArray(updates, Limits.MAX_ACTORS * Limits.MAX_SOURCES_PER_ACTOR * 2) then
		return nil, "InvalidProfileUpdates"
	end

	local desired: Graph.Catalog = table.clone(current)
	local pending: { [ActorTypes.ActorView]: { [string]: Validator.Profile } } = {}
	local rejection: string? = nil

	-- Multiple invalid contributions have one stable cause regardless of caller
	-- array order or Actor-key iteration order. Never publish a partial catalog.
	local function reject(reason: string): ()
		if rejection == nil or reason < rejection then
			rejection = reason
		end
	end

	for _, update: Types.ProfileUpdate in updates do
		if not Identity.Plain(update, { actor = true, sourceId = true, profile = true }) then
			reject("InvalidProfileUpdates")
			continue
		end

		local reason: string? = validateActor(update.actor)

		if reason ~= nil then
			reject(reason)
			continue
		end

		if update.actor == nil then
			reject("ActorViewUnavailable")
			continue
		end

		if not Identity.IsId(update.sourceId) then
			reject("InvalidProfileSourceId")
			continue
		end

		local profile: Validator.Profile? = nil

		if update.profile ~= nil then
			profile, reason = Validator.Normalize(update.profile, input)

			if profile == nil then
				reject(assert(reason, "ProfileCompilerFailureMissingReason"))
				continue
			end
		end

		local existing: { [string]: Validator.Profile }? = pending[update.actor]
		local sources: { [string]: Validator.Profile }

		if existing ~= nil then
			sources = existing
		else
			local previous: Graph.Graph? = current[update.actor]
			sources = if previous == nil then {} else table.clone(previous.sources)
			pending[update.actor] = sources
		end

		sources[update.sourceId] = if profile ~= nil and #profile.routes > 0 then profile else nil
	end

	-- Compile each complete prospective Actor graph once. Intermediate source
	-- priorities may conflict during a valid atomic exchange of contributions.
	for actor: ActorTypes.ActorView, sources: { [string]: Validator.Profile } in pending do
		local compiled: Graph.Graph?, reason: string? = Graph.Build(sources, current[actor], version)

		if compiled == nil then
			reject(assert(reason, "ProfileCompilerFailureMissingReason"))
			continue
		end

		desired[actor] = if next(sources) == nil then nil else compiled
	end

	if rejection ~= nil then
		return nil, rejection
	end

	local count: number = 0

	for _ in desired do
		count += 1
	end

	if count > Limits.MAX_ACTORS then
		return nil, "ProfileActorLimitExceeded"
	end

	if not Graph.Validate(desired, input) then
		return nil, "ProfileDependencyMissing"
	end

	return desired, nil
end

return Updates
