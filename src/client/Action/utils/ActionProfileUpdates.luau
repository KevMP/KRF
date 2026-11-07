--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local InputTypes = require(script.Parent.Parent.Parent.Input.types)
local Validator = require(script.Parent.Parent.ActionProfileValidator)
local Identity = require(script.Parent.ActionRouteIdentity)
local Graph = require(script.Parent.ActionProfileGraph)
local Limits = require(script.Parent.ActionRouteLimits)
local Updates = {}

function Updates.EqualSource(left: Validator.Profile?, right: Validator.Profile?): boolean
	if left == right then
		return true
	end

	if left == nil or right == nil or left.priority ~= right.priority or #left.routes ~= #right.routes then
		return false
	end

	for index: number, route: Validator.ValidatedRoute in left.routes do
		if not Validator.EqualRoute(route, right.routes[index]) then
			return false
		end
	end

	return true
end

-- Both ordinary replacement and future compound preflight use this compiler.
-- No resolver or observer is invoked and no installed state is mutated.
function Updates.Prepare(
	current: Graph.Catalog,
	updates: { Types.ProfileUpdate },
	input: InputTypes.InputGraphSnapshot,
	version: number,
	validateActor: (ActorTypes.ActorView?) -> string?
): (Graph.Catalog?, string?)
	if not Validator.IsArray(updates, Limits.MAX_PREPARED_PLANS) then
		return nil, "InvalidProfileUpdates"
	end

	local desired: Graph.Catalog = table.clone(current)
	local pending: { [ActorTypes.ActorView]: { [string]: Validator.Profile } } = {}

	for _, update: Types.ProfileUpdate in updates do
		if not Identity.Plain(update, { actor = true, sourceId = true, profile = true }) then
			return nil, "InvalidProfileUpdates"
		end

		local reason: string? = validateActor(update.actor)

		if reason ~= nil then
			return nil, reason
		end

		if update.actor == nil then
			return nil, "ActorViewUnavailable"
		end

		if not Identity.IsId(update.sourceId) then
			return nil, "InvalidProfileSourceId"
		end

		local profile: Validator.Profile? = nil

		if update.profile ~= nil then
			profile, reason = Validator.Normalize(update.profile, input)

			if profile == nil then
				return nil, reason
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
			return nil, reason
		end

		desired[actor] = if next(sources) == nil then nil else compiled
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
