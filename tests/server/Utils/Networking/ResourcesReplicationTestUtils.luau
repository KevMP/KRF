--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local ActorTypes = require(KRF.server.Actor.types)
local ResourceTypes = require(KRF.server.Resource.types)
local PropertyTypes = require(KRF.server.Property.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local NetworkingTypes = require(KRF.server.Networking.types)
local Registry: ResourceTypes.ResourceRegistry = require(KRF.server.Resource.ResourceRegistry)
local Controller = require(KRF.server.Resource.ResourceController)
local Adapter = require(KRF.server.Networking.utils.ResourcesReplication)
local ResourceUtils = require(script.Parent.Parent.Resource.ResourceControllerTestUtils)
local PublicationUtils = require(script.Parent.PublicationTestUtils)

export type Fixture = {
	actor: ActorTypes.Actor,
	resources: ResourceTypes.InternalResourceController,
	properties: PropertyTypes.PropertyController,
	definition: ReplicationTypes.ReplicationDomainDefinition,
	clock: { now: number, reads: number },
	commits: { NetworkingTypes.PublicationCommit },
	faults: { NetworkingTypes.PublicationFault },
	runtime: NetworkingTypes.PublicationRuntime?,
	disconnects: { () -> () },
}

local TestUtils = {}

function TestUtils.catalog(): { ResourceTypes.ResourceDefinition }
	return {
		{
			id = "Resource.Mana",
			visibility = "ClientVisible",
			autoAssign = true,
			initialValue = 40,
			min = { propertyName = "ManaMin", defaultBaseValue = 0 },
			max = { propertyName = "ManaMax", defaultBaseValue = 100 },
			regen = { rate = { propertyName = "ManaRegen", defaultBaseValue = 10 } },
		},
		{
			id = "Resource.Stamina",
			visibility = "ClientVisible",
			autoAssign = true,
			initialValue = 20,
			max = { value = 100 },
			regen = { rate = { value = 5 } },
		},
		{ id = "Resource.Rage", visibility = "ClientVisible", max = { value = 50 } },
		{ id = "Resource.Unassigned", visibility = "ClientVisible", max = { value = 100 } },
		{
			id = "Private.Secret",
			visibility = "ServerOnly",
			autoAssign = true,
			initialValue = 30,
			max = { propertyName = "PrivateMax", defaultBaseValue = 50 },
			regen = { rate = { propertyName = "PrivateRegen", defaultBaseValue = 4 } },
		},
	}
end

function TestUtils.new(catalog: { ResourceTypes.ResourceDefinition }?): Fixture
	Controller._setAutomaticSteppingEnabledForTests(false)
	ResourceUtils.resetAndLoadDefinitions(catalog or TestUtils.catalog())

	local actor: ActorTypes.Actor, properties: PropertyTypes.PropertyController =
		ResourceUtils.createActorWithPropertyController()

	actor.enabled = true

	local resources: ResourceTypes.InternalResourceController =
		Controller.new(actor) :: ResourceTypes.InternalResourceController

	assert(actor:SetController("ResourceController", resources), "Expected ResourceController installation")
	local clock = { now = 1000, reads = 0 }

	local definition: ReplicationTypes.ReplicationDomainDefinition? = Adapter.Build(
		Registry.GetAll(),
		function(): number
			clock.reads += 1

			return clock.now
		end
	)

	assert(definition ~= nil, "Visible catalog requires the declared Resources domain")

	return {
		actor = actor,
		resources = resources,
		properties = properties,
		definition = definition,
		clock = clock,
		commits = {},
		faults = {},
		runtime = nil,
		disconnects = {},
	}
end

function TestUtils.attach(
	fixture: Fixture,
	additional: { ReplicationTypes.ReplicationDomainDefinition }?
): NetworkingTypes.PublicationRuntime
	local definitions: { ReplicationTypes.ReplicationDomainDefinition } = { fixture.definition }

	for _, definition: ReplicationTypes.ReplicationDomainDefinition in additional or {} do
		table.insert(definitions, definition)
	end

	local runtime: NetworkingTypes.PublicationRuntime = PublicationUtils.createRuntime(definitions, {
		ReportFault = function(fault: NetworkingTypes.PublicationFault)
			table.insert(fixture.faults, fault)
		end,
	})

	fixture.runtime = runtime

	runtime:ObserveCommits(function(commit: NetworkingTypes.PublicationCommit)
		table.insert(fixture.commits, commit)
	end)

	local attached: boolean, reason: string? = runtime:AttachActor(fixture.actor)
	assert(attached, reason)

	return runtime
end

function TestUtils.snapshot(fixture: Fixture): Adapter.ReplicatedResourcesState
	return fixture.definition.snapshot(fixture.actor)
end

function TestUtils.step(fixture: Fixture, seconds: number): ()
	fixture.clock.now += seconds
	Controller.Step(seconds)
end

function TestUtils.destroy(fixture: Fixture): ()
	if fixture.runtime ~= nil then
		fixture.runtime:Destroy()
	end

	for _, disconnect in fixture.disconnects do
		disconnect()
	end

	fixture.resources:Destroy()
	fixture.properties:Destroy()
	Registry._resetForTests()
	Controller._setAutomaticSteppingEnabledForTests(true)
end

return TestUtils
