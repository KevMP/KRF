--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActorTypes = require(KRF.server.Actor.types)
local ServerNetworkingTypes = require(KRF.server.Networking.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local ServerTypes = require(KRF.server.types)
local Awareness: ServerNetworkingTypes.ActorAwarenessRuntimeModule =
	require(KRF.server.Networking.ActorAwarenessRuntime)
local Scheduling: ServerNetworkingTypes.AwarenessSchedulingModule =
	require(KRF.server.Networking.utils.AwarenessScheduling)
local Association: ServerNetworkingTypes.PlayerAssociationModule =
	require(KRF.server.Networking.utils.NativePlayerAssociation)
local Marker: ServerNetworkingTypes.ActorModelMarkerModule = require(KRF.server.Networking.utils.ActorModelMarker)
local Networking: ServerNetworkingTypes.ServerNetworking = require(KRF.server.Networking.ServerNetworking)
local ActorRuntime: ActorTypes.ActorRuntime = require(KRF.server.Actor.ActorRuntime)
local Server = require(KRF.server)

local originalNew: typeof(Awareness.new) = Awareness.new
local originalInstall: typeof(Marker.Install) = Marker.Install
local originalRemove: typeof(Marker.Remove) = Marker.Remove
local originalPublish: typeof(Networking.Publish) = Networking.Publish
local originalBudget: typeof(Scheduling.GetBudget) = Scheduling.GetBudget
local originalObserveStep: typeof(Scheduling.ObserveStep) = Scheduling.ObserveStep
local originalAssociation: typeof(Association.new) = Association.new
local created: number = 0
local destroyed: number = 0
local timeline: { string } = {}
local models: { Model } = {}
local publication: ServerNetworkingTypes.PublicationRuntime? = nil
local steps: { ServerNetworkingTypes.AwarenessStepBudget } = {}
local stepCallback: (() -> ())? = nil
local driverConnections: number = 0
local driverDisconnections: number = 0
local driverActive: boolean = false
local associationCreated: number = 0
local associationDestroyed: number = 0
local associationObservers: { (Model) -> () } = {}
local modelLookups: { Model } = {}
local installedDependencies: ServerNetworkingTypes.ActorAwarenessDependencies? = nil

beforeEach(function()
	Server._ResetForTests()
	created = 0
	destroyed = 0
	timeline = {}
	publication = nil
	steps = {}
	stepCallback = nil
	driverConnections = 0
	driverDisconnections = 0
	driverActive = false
	associationCreated = 0
	associationDestroyed = 0
	associationObservers = {}
	modelLookups = {}
	installedDependencies = nil
	Association.new = function(_players: Players?): ServerNetworkingTypes.PlayerAssociationSource
		associationCreated += 1
		return {
			GetPlayerFromCharacter = function(model: Model): Player?
				table.insert(modelLookups, model)
				return nil
			end,
			ObserveAssociationChanged = function(callback: (Model) -> ()): () -> ()
				table.insert(associationObservers, callback)
				return function(): ()
					local index: number? = table.find(associationObservers, callback)
					if index ~= nil then
						table.remove(associationObservers, index)
					end
				end
			end,
			Destroy = function(): ()
				associationDestroyed += 1
			end,
		}
	end
	Scheduling.GetBudget = function(): ServerNetworkingTypes.AwarenessStepBudget
		return { maxBytes = 96, maxRecords = 2 }
	end
	Scheduling.ObserveStep = function(callback: () -> ()): () -> ()
		driverConnections += 1
		driverActive = true
		stepCallback = callback
		return function(): ()
			if driverActive then
				driverDisconnections += 1
			end
			driverActive = false
		end
	end
	Awareness.new = function(
		canonical: ServerNetworkingTypes.PublicationRuntime,
		_catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
		_protocol: SharedNetworkingTypes.ClientProtocol,
		_dependencies: ServerNetworkingTypes.ActorAwarenessDependencies,
		_options: ServerNetworkingTypes.ActorAwarenessOptions
	): ServerNetworkingTypes.ActorAwarenessRuntime
		created += 1
		publication = canonical
		installedDependencies = _dependencies
		-- Record only framework lifecycle calls; all recipient behavior uses the real runtime specs.
		return {
			OnActorRegistered = function(
				_self: ServerNetworkingTypes.ActorAwarenessRuntime,
				actor: ActorTypes.Actor
			): ()
				expect(actor.enabled).toBe(true)
				expect(canonical:CaptureBaseline(actor)).never.toBeNil()
				table.insert(timeline, "Aware:" .. actor:GetId())
			end,
			OnActorUnregistering = function(
				_self: ServerNetworkingTypes.ActorAwarenessRuntime,
				actor: ActorTypes.Actor
			): ()
				expect(actor.enabled).toBe(false)
				expect(canonical:CaptureBaseline(actor)).never.toBeNil()
				table.insert(timeline, "Retired:" .. actor:GetId())
			end,
			RefreshPlayerAssociation = function(
				_self: ServerNetworkingTypes.ActorAwarenessRuntime,
				_actor: ActorTypes.Actor
			): ()
			end,
			GetActorForPlayer = function(
				_self: ServerNetworkingTypes.ActorAwarenessRuntime,
				_player: Player
			): ActorTypes.Actor?
				return nil
			end,
			GetPlayerForActor = function(
				_self: ServerNetworkingTypes.ActorAwarenessRuntime,
				_actor: ActorTypes.Actor
			): Player?
				return nil
			end,
			IsAware = function(
				_self: ServerNetworkingTypes.ActorAwarenessRuntime,
				_player: Player,
				_actor: ActorTypes.Actor
			): boolean
				return false
			end,
			GetHandle = function(
				_self: ServerNetworkingTypes.ActorAwarenessRuntime,
				_player: Player,
				_actor: ActorTypes.Actor
			): number?
				return nil
			end,
			RequestReplacementBaseline = function(
				_self: ServerNetworkingTypes.ActorAwarenessRuntime,
				_player: Player,
				_handle: number,
				_reason: string?
			): (boolean, string?)
				return false, "UnknownActorHandle"
			end,
			Step = function(
				_self: ServerNetworkingTypes.ActorAwarenessRuntime,
				maxBytes: number,
				maxRecords: number
			): ()
				table.insert(steps, { maxBytes = maxBytes, maxRecords = maxRecords })
			end,
			Destroy = function(_self: ServerNetworkingTypes.ActorAwarenessRuntime): ()
				destroyed += 1
			end,
		}
	end
	Marker.Install = function(actor: ActorTypes.Actor): (boolean, string?)
		table.insert(timeline, "Marker:" .. actor:GetId())
		return true, nil
	end
	Marker.Remove = function(actor: ActorTypes.Actor): ()
		table.insert(timeline, "Unmarked:" .. actor:GetId())
	end
end)
afterEach(function()
	Networking.Publish = originalPublish
	Server._ResetForTests()
	Awareness.new = originalNew
	Marker.Install = originalInstall
	Marker.Remove = originalRemove
	Scheduling.GetBudget = originalBudget
	Scheduling.ObserveStep = originalObserveStep
	Association.new = originalAssociation
	for _, model: Model in models do
		model:Destroy()
	end
	models = {}
end)

it("installs and owns the native Character association source used by the production awareness runtime", function()
	expect(Server.Init({})).toBe(true)
	expect(associationCreated).toBe(1)
	assert(installedDependencies ~= nil, "Expected production N4 dependencies")
	local character: Model = Instance.new("Model")
	table.insert(models, character)
	expect(installedDependencies.GetPlayerFromCharacter(character)).toBeNil()
	expect(modelLookups).toEqual({ character })
	local changed: { Model } = {}
	local unsubscribe: () -> () = installedDependencies.ObserveAssociationChanged(function(model: Model): ()
		table.insert(changed, model)
	end)
	expect(#associationObservers).toBe(1)
	associationObservers[1](character)
	expect(changed).toEqual({ character })
	unsubscribe()
	expect(associationObservers).toEqual({})
	Server._ResetForTests()
	Server._ResetForTests()
	expect(associationDestroyed).toBe(1)
end)

it("destroys the native association source when later startup activation rolls back", function()
	Networking.Publish = function(protocol: SharedNetworkingTypes.PreparedProtocol): (boolean, string?)
		local success: boolean, reason: string? = originalPublish(protocol)
		if not success then
			return false, reason
		end
		return false, "ForcedAssociationRollback"
	end
	local started: boolean, failure: ServerTypes.StartupFailure? = Server.Init({})
	expect(started).toBe(false)
	expect(failure).toEqual({ system = "Networking", reason = "ForcedAssociationRollback" })
	expect(associationCreated).toBe(1)
	expect(associationDestroyed).toBe(1)
end)

it("drives one bounded awareness Step from each production scheduling event", function()
	expect(Server.Init({})).toBe(true)
	expect(driverConnections).toBe(1)
	expect(steps).toEqual({})
	assert(stepCallback ~= nil, "Production Publish must subscribe to scheduling")
	for _ = 1, 3 do
		stepCallback()
	end
	expect(steps).toEqual({
		{ maxBytes = 96, maxRecords = 2 },
		{ maxBytes = 96, maxRecords = 2 },
		{ maxBytes = 96, maxRecords = 2 },
	})
end)

it("stops the production driver on teardown and ignores an already queued callback", function()
	expect(Server.Init({})).toBe(true)
	assert(stepCallback ~= nil, "Expected installed scheduling callback")
	local retained: () -> () = stepCallback
	retained()
	expect(#steps).toBe(1)
	Server._ResetForTests()
	Server._ResetForTests()
	expect(driverActive).toBe(false)
	expect(driverDisconnections).toBe(1)
	expect(destroyed).toBe(1)
	retained()
	expect(#steps).toBe(1)
end)

it("disconnects the driver when startup rolls back after Networking activation", function()
	Networking.Publish = function(protocol: SharedNetworkingTypes.PreparedProtocol): (boolean, string?)
		local success: boolean, reason: string? = originalPublish(protocol)
		if not success then
			return false, reason
		end
		return false, "ForcedDriverRollback"
	end
	local started: boolean, failure: ServerTypes.StartupFailure? = Server.Init({})
	expect(started).toBe(false)
	expect(failure).toEqual({ system = "Networking", reason = "ForcedDriverRollback" })
	expect(driverConnections).toBe(1)
	expect(driverDisconnections).toBe(1)
	expect(driverActive).toBe(false)
	expect(destroyed).toBe(1)
end)

it("creates and owns one awareness runtime alongside the startup-owned N3 publication runtime", function()
	expect(Server.Init({})).toBe(true)
	expect(created).toBe(1)
	expect(publication).toBe(Networking._GetPublicationRuntimeForTests())
	Server._ResetForTests()
	expect(destroyed).toBe(1)
	Server._ResetForTests()
	expect(destroyed).toBe(1)
end)

it("calls private Actor awareness and retirement synchronously in binding lifecycle order", function()
	expect(Server.Init({})).toBe(true)
	local model: Model = Instance.new("Model")
	model.Parent = workspace
	table.insert(models, model)
	local actor: ActorTypes.Actor?, reason: string? = ActorRuntime.RegisterActor(model)
	expect(reason).toBeNil()
	assert(actor ~= nil, "Expected registered Actor")
	expect(timeline).toEqual({ "Marker:" .. actor:GetId(), "Aware:" .. actor:GetId() })
	expect(ActorRuntime.UnregisterActor(actor)).toBe(true)
	expect(timeline).toEqual({
		"Marker:" .. actor:GetId(),
		"Aware:" .. actor:GetId(),
		"Retired:" .. actor:GetId(),
		"Unmarked:" .. actor:GetId(),
	})
	assert(publication ~= nil, "Expected startup-owned publication")
	expect(publication:CaptureBaseline(actor)).toBeNil()
end)

it("destroys the installed awareness runtime when later Networking publication rolls back", function()
	Networking.Publish = function(protocol: SharedNetworkingTypes.PreparedProtocol): (boolean, string?)
		local success: boolean, reason: string? = originalPublish(protocol)
		if not success then
			return false, reason
		end
		return false, "ForcedAwarenessRollback"
	end
	local started: boolean, failure: ServerTypes.StartupFailure? = Server.Init({})
	expect(started).toBe(false)
	expect(failure).toEqual({ system = "Networking", reason = "ForcedAwarenessRollback" })
	expect(created).toBe(1)
	expect(destroyed).toBe(1)
	expect(Networking._IsInitialized()).toBe(false)
	expect(Networking._GetPublicationRuntimeForTests()).toBeNil()
end)
