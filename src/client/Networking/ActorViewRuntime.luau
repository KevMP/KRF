--!strict
local Types = require(script.Parent.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.shared.Networking.types)
local Registry = require(script.Parent.Parent.Actor.ActorViewRegistry)
local PublicTypes = require(script.Parent.Parent.Actor.types)
local Actors = require(script.Parent.Parent.Actor.ActorView)
local RegistryOwner = require(script.Parent.Parent.Actor.utils.ActorViewRegistryState)
local Publication = require(script.Parent.utils.ActorViewPublication)
local Recovery = require(script.Parent.utils.ActorViewRecovery)
local Constants = require(script.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)

local ActorViewRuntime = {}

type State = {
	actor: Types.ActorStreamRecord,
	model: Model?,
	owner: PublicTypes.ActorViewOwner?,
	domains: { [string]: PublicTypes.DomainViewOwner },
	revision: number?,
	status: "Live" | "AwaitingBaseline" | "Halted",
	recovery: Recovery.Recovery,
}

local function validRevision(revision: number): boolean
	return type(revision) == "number" and revision >= 0 and revision <= Constants.MAX_COUNTER and revision % 1 == 0
end

function ActorViewRuntime.new(
	protocol: SharedNetworkingTypes.ClientProtocol,
	schemas: SharedNetworkingTypes.ActorSchemaCatalog,
	options: Types.ActorViewOptions
): Types.ActorViewRuntime
	local plan: Publication.Plan = Publication.Compile(protocol, schemas)
	local states: { [number]: State } = {}
	-- The Actor stream runtime owns handle retirement. Weak record tombstones additionally protect
	-- retained private callbacks without duplicating its lifetime-growing handle set.
	local retired: { [Types.ActorStreamRecord]: boolean } = setmetatable({}, { __mode = "k" })
	local destroyed: boolean = false
	local admit: () -> boolean = Recovery.Admission(options.Now)

	local function report(actor: Types.ActorStreamRecord, reason: string, terminal: boolean?): ()
		pcall(options.ReportFault, { actorId = actor.actorId, reason = reason }, terminal)
	end

	local function halt(state: State, reason: string): ()
		if state.status == "Halted" then
			return
		end

		state.status = "Halted"
		state.recovery.Cancel()

		for _, domain: PublicTypes.DomainViewOwner in state.domains do
			domain:Destroy()
		end

		state.domains = {}

		local owner: PublicTypes.ActorViewOwner? = state.owner

		if owner ~= nil then
			local membership: PublicTypes.DomainMembershipChange? = owner:InstallDomains({})
			owner:InstallUnavailable()

			if membership ~= nil then
				owner:NotifyDomainsChanged(membership)
			end

			owner:NotifyUnavailable()
		end

		report(state.actor, reason, true)
	end

	local function stateFor(actor: Types.ActorStreamRecord): State?
		if destroyed or retired[actor] then
			return nil
		end

		local state: State? = states[actor.handle]

		if state ~= nil then
			if state.actor ~= actor then
				report(actor, "ActorHandleConflict")

				return nil
			end

			return state
		end

		local recovery: Recovery.Recovery = Recovery.new(options, actor, admit, function(reason: string)
			report(actor, reason)
		end, function(reason: string)
			local current: State? = states[actor.handle]

			if current ~= nil then
				halt(current, reason)
			end
		end)

		local created: State = {
			actor = actor,
			model = actor.model,
			owner = nil,
			domains = {},
			revision = nil,
			status = "AwaitingBaseline",
			recovery = recovery,
		}

		states[actor.handle] = created

		return created
	end

	local function recover(state: State, reason: string): ()
		state.status = "AwaitingBaseline"
		report(state.actor, reason)
		state.recovery.Start()
	end

	local function remove(actor: Types.ActorStreamRecord): ()
		if retired[actor] then
			return
		end

		retired[actor] = true

		local state: State? = states[actor.handle]

		if state == nil or state.actor ~= actor then
			return
		end

		states[actor.handle] = nil
		state.recovery.Cancel()
		local owner: PublicTypes.ActorViewOwner? = state.owner

		if owner ~= nil then
			RegistryOwner.Removing:Fire(owner.view)
			RegistryOwner.Remove(owner.view)
			owner:Destroy()
		end
	end

	local function notify(stage: Publication.Stage): ()
		for _, changed: Publication.Change in stage.changes do
			changed.owner:NotifyChanged(changed.change)
		end

		for _, event: Publication.Event in stage.events do
			event.owner:FireEvent(event.id, event.payload)
		end
	end

	local function modelChanged(actor: Types.ActorStreamRecord, model: Model?): ()
		local state: State? = stateFor(actor)

		if state == nil then
			return
		end

		local owner: PublicTypes.ActorViewOwner? = state.owner

		if owner == nil then
			state.model = model

			return
		end

		local previous: Model? = owner.view:GetModel()

		if previous == model then
			return
		end

		local installed: boolean, reason: string? = RegistryOwner.InstallModel(owner.view, previous, model)

		if not installed then
			report(actor, reason or "ActorModelConflict")

			return
		end

		state.model = model
		owner:InstallModel(model)
		owner:NotifyModelChanged(previous, model)
	end

	return {
		registry = Registry,
		consumer = {
			OnBaselineReady = function(
				actor: Types.ActorStreamRecord,
				revision: number,
				domains: { [string]: SharedNetworkingTypes.ActorDomainTruth }
			): ()
				local state: State? = stateFor(actor)

				if state == nil or state.status == "Halted" then
					return
				end

				if not validRevision(revision) then
					recover(state, "InvalidActorRevision")

					return
				end

				local prepared: boolean, stage: Publication.Stage?, reason: string? =
					pcall(plan.Baseline, state.domains, domains)

				if not prepared or stage == nil then
					recover(state, if prepared then reason or "InvalidActorState" else "InvalidActorState")

					return
				end

				local owner: PublicTypes.ActorViewOwner? = state.owner

				if owner == nil then
					owner = Actors.new(actor.actorId, state.model, stage.domains)
					assert(owner ~= nil, "ActorViewConstructionFailed")
					local installed: boolean
					installed, reason = RegistryOwner.Install(owner.view)

					if not installed then
						owner:Destroy()
						halt(state, reason or "ActorIdConflict")

						return
					end

					state.owner = owner
					state.domains = stage.domains
					state.revision = revision
					state.status = "Live"
					state.recovery.Cancel(true)
					RegistryOwner.Added:Fire(owner.view)

					return
				end

				local previous: { [string]: PublicTypes.DomainViewOwner } = state.domains

				for _, changed: Publication.Change in stage.changes do
					changed.owner:InstallState(changed.change.current)
				end

				local membership: PublicTypes.DomainMembershipChange? = owner:InstallDomains(stage.domains)

				state.domains = stage.domains
				state.revision = revision
				state.status = "Live"
				state.recovery.Cancel(true)

				for id: string, domain: PublicTypes.DomainViewOwner in previous do
					if stage.domains[id] == nil then
						domain:Destroy()
					end
				end

				if membership ~= nil then
					owner:NotifyDomainsChanged(membership)
				end

				notify(stage)
			end,
			OnCommitReady = function(
				actor: Types.ActorStreamRecord,
				revision: number,
				patches: { SharedNetworkingTypes.ActorDomainPatch },
				events: { SharedNetworkingTypes.ActorEvent }
			): ()
				local state: State? = stateFor(actor)

				if state == nil or state.status ~= "Live" then
					return
				end

				if
					not validRevision(revision)
					or state.revision == Constants.MAX_COUNTER
					or revision ~= (state.revision :: number) + 1
				then
					recover(state, "UnexpectedActorRevision")

					return
				end

				local prepared: boolean, stage: Publication.Stage?, reason: string? =
					pcall(plan.Commit, state.domains, patches, events)

				if not prepared or stage == nil then
					recover(state, if prepared then reason or "InvalidActorPatch" else "InvalidActorPatch")

					return
				end

				for _, changed: Publication.Change in stage.changes do
					changed.owner:InstallState(changed.change.current)
				end

				state.revision = revision
				notify(stage)
			end,
			OnActorFault = function(actor: Types.ActorStreamRecord, reason: string): ()
				local state: State? = stateFor(actor)

				if state ~= nil and state.status ~= "Halted" then
					recover(state, reason)
				end
			end,
			OnActorHalted = function(actor: Types.ActorStreamRecord): ()
				local state: State? = stateFor(actor)

				if state == nil or state.status == "Halted" then
					return
				end

				halt(state, "ActorStreamHalted")
			end,
			OnActorRemoved = function(actor: Types.ActorStreamRecord): ()
				if not destroyed then
					remove(actor)
				end
			end,
			OnModelBound = function(actor: Types.ActorStreamRecord, model: Model): ()
				modelChanged(actor, model)
			end,
			OnModelUnbound = function(actor: Types.ActorStreamRecord, model: Model): ()
				local state: State? = states[actor.handle]

				if state ~= nil and state.model == model then
					modelChanged(actor, nil)
				end
			end,
		},
		_InspectForTests = function(_self: Types.ActorViewRuntime, handle: number): Types.ActorViewDiagnostics?
			local state: State? = states[handle]

			return if state ~= nil
				then { revision = state.revision, status = state.status, bufferedCommitCount = 0 }
				else nil
		end,
		Destroy = function(_self: Types.ActorViewRuntime): ()
			if destroyed then
				return
			end

			destroyed = true

			for _, state: State in table.clone(states) do
				remove(state.actor)
			end

			table.clear(states)
			table.clear(retired)
		end,
	}
end

return ActorViewRuntime
