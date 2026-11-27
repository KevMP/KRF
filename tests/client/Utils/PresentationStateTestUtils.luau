--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.client.Actor.types)
local NetworkingTypes = require(KRF.client.Networking.types)
local Types = require(KRF.client.Presentation.types)
local ActorView: ActorTypes.ActorViewModule = require(KRF.client.Actor.ActorView)
local DomainView: ActorTypes.DomainViewModule = require(KRF.client.Actor.DomainView)
local Actors: ActorTypes.ActorViewRegistryOwner = require(KRF.client.Actor.utils.ActorViewRegistryState)
local Registry = require(KRF.client.Presentation.PresentationRegistry)
local Runtime = require(KRF.client.Presentation.PresentationRuntime)

export type TagState = { [string]: { read stackCount: number, read expiresAt: number? } }
export type ActionState = { [number]: string }

export type ResourceState = {
	[string]: {
		read anchorValue: number,
		read anchorTime: number,
		read min: number,
		read max: number,
		read regenRate: number?,
	},
}

export type ReadinessObserver = (ActorTypes.ActorView, NetworkingTypes.ActorViewStateReadiness) -> ()

export type Readiness = {
	source: NetworkingTypes.ActorViewStateReadinessSource,
	ready: { [ActorTypes.ActorView]: boolean },
	observers: { [ReadinessObserver]: boolean },
}

export type Actor = {
	owner: ActorTypes.ActorViewOwner,
	view: ActorTypes.ActorView,
	tags: ActorTypes.DomainViewOwner,
	actions: ActorTypes.DomainViewOwner,
	resources: ActorTypes.DomainViewOwner,
}

local TestUtils = {}
local owned: { ActorTypes.ActorViewOwner } = {}
local shutdown: (() -> ())? = nil

local function freeze(state: { [any]: any }): { [any]: any }
	local copy: { [any]: any } = {}

	for key: any, value: any in state do
		copy[key] = if type(value) == "table" then table.freeze(table.clone(value)) else value
	end

	return table.freeze(copy)
end

function TestUtils.readiness(): Readiness
	local fixture: Readiness

	fixture = {
		ready = {},
		observers = {},
		source = table.freeze({
			IsStateReady = function(
				_self: NetworkingTypes.ActorViewStateReadinessSource,
				actor: ActorTypes.ActorView
			): boolean
				return fixture.ready[actor] == true
			end,
			ObserveStateReadiness = function(
				_self: NetworkingTypes.ActorViewStateReadinessSource,
				callback: ReadinessObserver
			): () -> ()
				fixture.observers[callback] = true

				return function(): ()
					fixture.observers[callback] = nil
				end
			end,
		}),
	}

	return fixture
end

function TestUtils.setReady(fixture: Readiness, actor: ActorTypes.ActorView, ready: boolean): ()
	fixture.ready[actor] = ready

	for callback: ReadinessObserver in table.clone(fixture.observers) do
		callback(actor, if ready then "Ready" else "Stale")
	end
end

function TestUtils.actor(id: string, tags: TagState?, actions: ActionState?, resources: ResourceState?): Actor
	local tagDomain: ActorTypes.DomainViewOwner =
		assert(DomainView.new("KRF.Tags", freeze(tags or {}), { "Added", "Refreshed", "Removed", "Expired" }))

	local actionDomain: ActorTypes.DomainViewOwner =
		assert(DomainView.new("KRF.Actions", freeze(actions or {}), { "Started", "Ended", "Interrupted" }))

	local resourceDomain: ActorTypes.DomainViewOwner =
		assert(DomainView.new("KRF.Resources", freeze(resources or {}), {}))

	local owner: ActorTypes.ActorViewOwner = assert(ActorView.new(id, nil, {
		["KRF.Tags"] = tagDomain,
		["KRF.Actions"] = actionDomain,
		["KRF.Resources"] = resourceDomain,
	}))

	table.insert(owned, owner)
	assert(Actors.Install(owner.view))

	return { owner = owner, view = owner.view, tags = tagDomain, actions = actionDomain, resources = resourceDomain }
end

function TestUtils.commit(domain: ActorTypes.DomainViewOwner, state: { [any]: any }): ()
	local previous: any = domain.view:GetState()
	local current: { [any]: any } = freeze(state)
	domain:InstallState(current)
	domain:NotifyChanged(table.freeze({ previous = previous, current = current, source = "Commit" :: "Commit" }))
end

function TestUtils.install(
	definitions: { any },
	readiness: Readiness?,
	policies: Types.ActionPredictionPolicyCatalog?,
	prediction: Types.PresentationPredictionPort?
): ()
	local catalog: Types.PresentationCatalog = assert(Registry.Prepare(definitions, policies))
	shutdown = assert(Runtime.Install(catalog, if readiness ~= nil then readiness.source else nil, prediction))
end

function TestUtils.reset(): ()
	if shutdown ~= nil then
		shutdown()
		shutdown = nil
	end

	Actors.Reset()

	for _, owner: ActorTypes.ActorViewOwner in owned do
		owner:Destroy()
	end

	table.clear(owned)
end

return TestUtils
