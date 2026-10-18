--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudioTestService = game:GetService("StudioTestService")
local KRF = ReplicatedStorage.Packages.KRF
local Server = require(KRF.server)
local ActorTypes = require(KRF.server.Actor.types)
local ReplicationTypes = require(KRF.server.Replication.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Compiler: SharedNetworkingTypes.CodecCompiler = require(KRF.shared.Networking.CodecCompiler)
local Networking = require(KRF.server.Networking.ServerNetworking)
local control: RemoteEvent = ReplicatedStorage:WaitForChild("NetworkingTestControl") :: RemoteEvent

local finished: boolean = false
local readyCount: number = 0
local closedCount: number = 0
local callbackCalls: number = 0
local compileCalls: number = 0
local initialCompileCalls: number = 0
local reports: { [Player]: string } = {}
local firstCodebook: string? = nil
local MARKER: buffer = buffer.fromstring("KRF engine ordering marker")

local function finish(success: boolean, reason: string?): ()
	if finished then
		return
	end

	finished = true

	StudioTestService:EndTest({
		success = success,
		reason = reason,
		readyCount = readyCount,
		closedCount = closedCount,
		compileCalls = compileCalls,
		callbackCalls = callbackCalls,
	})
end

task.delay(30, function(): ()
	finish(false, "Native networking timeout")
end)

local originalCompile: typeof(Compiler.Compile) = Compiler.Compile

Compiler.Compile = function(
	schema: SharedNetworkingTypes.CompiledSchema
): (SharedNetworkingTypes.CompiledCodec?, string?)
	compileCalls += 1

	return originalCompile(schema)
end

local definitions: { ReplicationTypes.ReplicationDomainDefinition } = {}

for _, id: string in { "Game.Beta", "Game.Alpha" } do
	table.insert(definitions, {
		id = id,
		state = Schema.Struct({ active = Schema.Boolean }),
		events = { { id = "Changed", payload = Schema.U8 }, { id = "Reset", payload = Schema.Boolean } },
		snapshot = function(_actor: ActorTypes.Actor): any
			callbackCalls += 1

			return { active = false }
		end,
		observe = function(
			_actor: ActorTypes.Actor,
			_callback: ReplicationTypes.ReplicationDomainOnCommitted
		): (() -> ())?
			callbackCalls += 1

			return nil
		end,
	})
end

local initialized: boolean, failure: Server.StartupFailure? = Server.Init({ replicationDomains = definitions })

if not initialized then
	finish(false, if failure ~= nil then failure.reason else "Server initialization failed")

	return
end

initialCompileCalls = compileCalls

Networking.ObserveClientReady(function(player: Player): ()
	readyCount += 1
	local sent: boolean, reason: string? = Networking.SendReliable(player, MARKER)

	if not sent then
		finish(false, reason)
	end
end)

Networking.ObserveClientClosed(function(player: Player): ()
	closedCount += 1

	if Networking.IsClientReady(player) then
		finish(false, "Closed player remained ready")

		return
	end

	if readyCount == 2 and closedCount == 1 then
		finish(
			compileCalls == initialCompileCalls and callbackCalls == 0,
			if compileCalls ~= initialCompileCalls then "Server codecs recompiled during handshake" else nil
		)
	end
end)

control.OnServerEvent:Connect(function(player: Player, payload: any): ()
	if finished then
		return
	end

	if typeof(payload) ~= "buffer" then
		finish(false, "Test report was not a buffer")

		return
	end

	local report: string = buffer.tostring(payload)

	if string.sub(report, 1, 6) ~= "Ready|" then
		finish(false, report)

		return
	end

	if not Networking.IsClientReady(player) then
		finish(false, "Client returned before server readiness")

		return
	end

	local codebook: string = string.sub(report, 7)

	if firstCodebook == nil then
		firstCodebook = codebook
	elseif firstCodebook ~= codebook then
		finish(false, "Client codebooks differed")

		return
	end

	reports[player] = codebook

	local count: number = 0

	for _ in reports do
		count += 1
	end

	if count == 2 then
		control:FireClient(player, buffer.fromstring("Leave"))
	end
end)
