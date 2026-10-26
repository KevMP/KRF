--!strict
local Players = game:GetService("Players")
local Types = require(script.Parent.Parent.types)
local ReplicationTypes = require(script.Parent.Parent.Parent.Replication.types)
local SharedNetworkingTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Handshake = require(script.Parent.Parent.ServerHandshake)
local PublicationRuntime = require(script.Parent.Parent.PublicationRuntime)
local PublicationLifecycle = require(script.Parent.ActorPublicationLifecycle)
local Awareness = require(script.Parent.Parent.ActorAwarenessRuntime)
local AwarenessLifecycle = require(script.Parent.ActorAwarenessLifecycle)
local Scheduling = require(script.Parent.AwarenessScheduling)
local NativeAssociation = require(script.Parent.NativePlayerAssociation)
local ActorConstants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)
local Resync = require(script.Parent.Parent.ResyncRuntime)
local Commands = require(script.Parent.Parent.ServerCommandRuntime)
local CommandConstants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)
local Hints = require(script.Parent.Parent.ServerHintRuntime)
local HintSender = require(script.Parent.HintSender)
local Diagnostics = require(script.Parent.NetworkingDiagnosticsState)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local SendMetrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingSendMetrics)
local HintState = require(script.Parent.HintRuntimeState)

local Installation = {}
Installation.__index = Installation

type State = {
	transports: SharedNetworkingTypes.OwnedTransport,
	initialized: boolean,
	destroyed: boolean,
	runtime: Types.ServerHandshake?,
	publication: Types.PublicationRuntime?,
	listeners: { RBXScriptConnection },
	awareness: Types.ActorAwarenessRuntime?,
	association: Types.PlayerAssociationSource?,
	stopDriver: (() -> ())?,
	resync: Types.ResyncRuntime?,
	commandRuntime: Types.ServerCommandRuntime?,
	hintRuntime: Types.ServerHintRuntime?,
	hintSender: Types.HintSenderRuntime?,
}

export type Runtime = typeof(setmetatable({} :: State, Installation))

function Installation.new(transports: SharedNetworkingTypes.OwnedTransport): Runtime
	return setmetatable(
		{ transports = transports, listeners = {}, initialized = false, destroyed = false },
		Installation
	)
end

function Installation._installHints(
	self: Runtime,
	protocol: SharedNetworkingTypes.ClientProtocol,
	catalog: Types.PreparedHintCatalog?,
	created: Types.ActorAwarenessRuntime
): ()
	local hasC2S = false
	local hasS2C = false
	local hintCatalog = catalog

	for _, definition in if hintCatalog ~= nil then hintCatalog.orderedDefinitions else {} do
		if definition.direction == "ClientToServer" then
			hasC2S = true
		else
			hasS2C = true
		end
	end

	if hasC2S and hintCatalog ~= nil then
		self.hintRuntime = Hints.new(hintCatalog, protocol, {
			Now = os.clock,
			IsClientReady = function(player: Player): boolean
				return self:IsClientReady(player)
			end,
			ObserveClientReady = function(callback: (Player) -> ()): () -> ()
				return self:ObserveClientReady(callback)
			end,
			ObserveClientClosed = function(callback: (Player) -> ()): () -> ()
				return self:ObserveClientClosed(callback)
			end,
			ObserveActorRemoved = function(callback): () -> ()
				return created:ObserveActorRemoved(callback)
			end,
			awareness = created,
		})
	end

	if hasS2C then
		local sender = HintSender.new(protocol, {
			Now = os.clock,
			IsClientReady = function(player: Player): boolean
				return self:IsClientReady(player)
			end,
			ObserveClientReady = function(callback: (Player) -> ()): () -> ()
				return self:ObserveClientReady(callback)
			end,
			ObserveClientClosed = function(callback: (Player) -> ()): () -> ()
				return self:ObserveClientClosed(callback)
			end,
			ObserveActorRemoved = function(callback): () -> ()
				return created:ObserveActorRemoved(callback)
			end,
			SendUnreliable = function(player: Player, payload: buffer): ()
				if self.initialized and player.Parent == Players then
					SendMetrics.Record(Diagnostics.GetConnection(player), false, payload)
					self.transports.unreliable:FireClient(player, payload)
				end
			end,
			awareness = created,
		})

		self.hintSender = sender :: Types.HintSenderRuntime
		HintState.Install(self.hintSender)
	end
end

function Installation.Start(
	self: Runtime,
	protocol: SharedNetworkingTypes.PreparedProtocol,
	preparedCatalog: ReplicationTypes.PreparedReplicationDomainCatalog?,
	preparedCommands: Types.PreparedCommandCatalog?,
	preparedHints: Types.PreparedHintCatalog?
): ()
	if preparedCatalog ~= nil then
		self.publication = PublicationRuntime.new(preparedCatalog)
		PublicationLifecycle.Install(self.publication)
	end

	local handshake: Types.ServerHandshake = Handshake.new(protocol, {
		SendReliable = function(player: Player, payload: buffer): ()
			SendMetrics.Record(Diagnostics.GetConnection(player), true, payload)
			self.transports.reliable:FireClient(player, payload)
		end,
	})

	self.runtime = handshake
	handshake:ObserveClientClosed(Diagnostics.Close)

	if self.publication ~= nil and preparedCatalog ~= nil then
		local source: Types.PlayerAssociationSource = NativeAssociation.new()

		self.association = source

		local created: Types.ActorAwarenessRuntime = Awareness.new(
			self.publication,
			preparedCatalog,
			protocol.runtime,
			{
				IsClientReady = function(player: Player): boolean
					return self:IsClientReady(player)
				end,
				ObserveClientReady = function(callback: (Player) -> ()): () -> ()
					return self:ObserveClientReady(callback)
				end,
				ObserveClientClosed = function(callback: (Player) -> ()): () -> ()
					return self:ObserveClientClosed(callback)
				end,
				SendReliable = function(player: Player, payload: buffer): (boolean, string?)
					return self:SendReliable(player, payload)
				end,
				GetPlayerFromCharacter = source.GetPlayerFromCharacter,
				ObserveAssociationChanged = source.ObserveAssociationChanged,
				CloseConnection = function(player: Player, _reason: string): ()
					handshake:Close(player)
				end,
				ReportFault = function(fault: Types.ActorAwarenessFault)
					warn(
						"[Networking] Actor stream halted actorId="
							.. fault.actorId
							.. " recipient="
							.. tostring(fault.player)
							.. " reason="
							.. fault.reason
					)
				end,
			},
			{
				maxBaselineBytes = ActorConstants.MAX_BASELINE_BYTES,
				maxChunkBytes = ActorConstants.CHUNK_BYTES,
				maxQueuedBytes = ActorConstants.MAX_QUEUED_BYTES,
				maxEvents = ActorConstants.MAX_EVENTS,
				maxHandle = ActorConstants.MAX_COUNTER,
				maxRevision = ActorConstants.MAX_COUNTER,
			}
		)

		self.awareness = created
		AwarenessLifecycle.Install(created)

		local commandCatalog: Types.PreparedCommandCatalog = preparedCommands
			or { definitionsById = {}, orderedDefinitions = {} }

		self.commandRuntime = Commands.new(commandCatalog, protocol.runtime, {
			Now = os.clock,
			IsClientReady = function(player: Player): boolean
				return self:IsClientReady(player)
			end,
			ObserveClientReady = function(callback: (Player) -> ()): () -> ()
				return self:ObserveClientReady(callback)
			end,
			ObserveClientClosed = function(callback: (Player) -> ()): () -> ()
				return self:ObserveClientClosed(callback)
			end,
			awareness = created,
			ReportFault = function(player: Player, faultReason: string): ()
				if faultReason == "CommandInternalFault" then
					-- This path closes the connection; retain its terminal evidence.
					warn("[Networking] command fault recipient=" .. tostring(player) .. " reason=" .. faultReason)
				else
					Metrics.Warn(
						Diagnostics.FindConnection(player) or Diagnostics.GetServer(),
						"CommandFault",
						faultReason
					)
				end
			end,
			CloseConnection = function(player: Player, _reason: string): ()
				handshake:Close(player)
			end,
		})

		self.resync = Resync.new({
			Now = os.clock,
			IsClientReady = function(player: Player): boolean
				return self:IsClientReady(player)
			end,
			ObserveClientClosed = function(callback: (Player) -> ()): () -> ()
				return self:ObserveClientClosed(callback)
			end,
			RequestReplacementBaseline = function(player: Player, handle: number, reason: string?): (boolean, string?)
				return self:RequestReplacementBaseline(player, handle, reason)
			end,
		}, {
			windowSeconds = ActorConstants.RESYNC_WINDOW_SECONDS,
			maxRequestsPerClient = ActorConstants.MAX_RESYNC_PER_CLIENT,
			maxRequestsPerActor = ActorConstants.MAX_RESYNC_PER_ACTOR,
		})

		local budget: Types.AwarenessStepBudget = Scheduling.GetBudget()

		self:_installHints(protocol.runtime, preparedHints, created)

		self.stopDriver = Scheduling.ObserveStep(function()
			if self.initialized and self.awareness == created then
				if self.commandRuntime ~= nil then
					self.commandRuntime:Step()
				end

				-- A handler may tear Networking down during dispatch.
				if not self.initialized or self.awareness ~= created then
					return
				end

				created:Step(budget.maxBytes, budget.maxRecords)

				if self.initialized and self.awareness == created and self.hintRuntime ~= nil then
					self.hintRuntime:Step()
				end

				if self.initialized and self.awareness == created and self.hintSender ~= nil then
					self.hintSender:Step()
				end
			end
		end)
	end

	table.insert(
		self.listeners,
		self.transports.reliable.OnServerEvent:Connect(function(player: Player, payload: any, ...: any): ()
			if self.initialized and player.Parent == Players then
				if
					self.commandRuntime ~= nil
					and typeof(payload) == "buffer"
					and buffer.len(payload) > 0
					and buffer.readu8(payload, 0) == CommandConstants.REQUEST_KIND
				then
					self.commandRuntime:Handle(player, payload, ...)
				elseif
					self.resync ~= nil
					and typeof(payload) == "buffer"
					and buffer.len(payload) > 0
					and buffer.readu8(payload, 0) == ActorConstants.RESYNC_PACKET_KIND
				then
					self.resync:Handle(player, payload, ...)
				else
					handshake:Handle(player, payload, ...)
				end
			end
		end)
	)

	table.insert(
		self.listeners,
		Players.PlayerRemoving:Connect(function(player: Player): ()
			handshake:Close(player)
		end)
	)

	if self.hintRuntime ~= nil then
		table.insert(
			self.listeners,
			self.transports.unreliable.OnServerEvent:Connect(function(player: Player, payload: any, ...: any): ()
				if self.initialized and player.Parent == Players and self.hintRuntime ~= nil then
					self.hintRuntime:Handle(player, payload, ...)
				end
			end)
		)
	end

	self.initialized = true
end

function Installation.IsClientReady(self: Runtime, player: Player): boolean
	return self.runtime ~= nil and (self.runtime :: Types.ServerHandshake):IsClientReady(player)
end

function Installation.ObserveClientReady(self: Runtime, callback: (Player) -> ()): () -> ()
	assert(self.runtime ~= nil, "NetworkingNotInitialized")

	return (self.runtime :: Types.ServerHandshake):ObserveClientReady(callback)
end

function Installation.ObserveClientClosed(self: Runtime, callback: (Player) -> ()): () -> ()
	assert(self.runtime ~= nil, "NetworkingNotInitialized")

	return (self.runtime :: Types.ServerHandshake):ObserveClientClosed(callback)
end

function Installation.SendReliable(self: Runtime, player: Player, payload: buffer): (boolean, string?)
	if self.runtime == nil then
		return false, "ClientNotReady"
	end

	return (self.runtime :: Types.ServerHandshake):Send(player, payload)
end

function Installation.RequestReplacementBaseline(
	self: Runtime,
	player: Player,
	handle: number,
	reason: string?
): (boolean, string?)
	if not self.initialized or self.awareness == nil then
		return false, "ClientNotReady"
	end

	return (self.awareness :: Types.ActorAwarenessRuntime):RequestReplacementBaseline(player, handle, reason)
end

function Installation.Destroy(self: Runtime): ()
	if self.destroyed then
		return
	end

	self.destroyed = true
	self.initialized = false
	HintState.Install(nil)

	if self.hintSender ~= nil then
		self.hintSender:Destroy()
		self.hintSender = nil
	end

	if self.hintRuntime ~= nil then
		self.hintRuntime:Destroy()
		self.hintRuntime = nil
	end

	if self.commandRuntime ~= nil then
		self.commandRuntime:Destroy()
		self.commandRuntime = nil
	end

	if self.resync ~= nil then
		self.resync:Destroy()
		self.resync = nil
	end

	AwarenessLifecycle.Install(nil)

	if self.stopDriver ~= nil then
		self.stopDriver()
		self.stopDriver = nil
	end

	if self.awareness ~= nil then
		self.awareness:Destroy()
		self.awareness = nil
	end

	if self.association ~= nil then
		self.association.Destroy()
		self.association = nil
	end

	PublicationLifecycle.Install(nil)

	if self.publication ~= nil then
		self.publication:Destroy()
		self.publication = nil
	end

	for _, listener: RBXScriptConnection in self.listeners do
		listener:Disconnect()
	end

	table.clear(self.listeners)

	if self.runtime ~= nil then
		(self.runtime :: Types.ServerHandshake):Destroy()
		self.runtime = nil
	end

	self.transports.Destroy()

	Diagnostics.Stop()
end

return Installation
