--!strict
local Types = require(script.Parent.Parent.types)
local ActorTypes = require(script.Parent.Parent.Parent.Actor.types)
local SharedTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Context = require(script.Parent.HintContext)
type Latest = { actor: ActorTypes.Actor?, sequence: number }

export type Channel = {
	player: Player,
	diagnostics: SharedTypes.DiagnosticCollector?,
	current: () -> boolean,
	latest: { [string]: Latest },
	latestCount: number,
	active: boolean,
}

local Dispatch = {}
Dispatch.__index = Dispatch

type State = {
	catalog: Types.PreparedHintCatalog,
	protocol: SharedTypes.ClientProtocol,
	awareness: Types.ActorAwarenessRuntime,
	limits: { maxLatestKeys: number, maxGlobalLatestKeys: number },
	keys: number,
}

export type Runtime = typeof(setmetatable({} :: State, Dispatch))

function Dispatch.new(
	catalog: Types.PreparedHintCatalog,
	protocol: SharedTypes.ClientProtocol,
	awareness: Types.ActorAwarenessRuntime,
	limits: { maxLatestKeys: number, maxGlobalLatestKeys: number }
): Runtime
	return setmetatable({
		catalog = catalog,
		protocol = protocol,
		awareness = awareness,
		limits = limits,
		keys = 0,
	}, Dispatch)
end

function Dispatch.Open(
	_self: Runtime,
	player: Player,
	diagnostics: SharedTypes.DiagnosticCollector?,
	current: () -> boolean
): Channel
	return { player = player, diagnostics = diagnostics, current = current, latest = {}, latestCount = 0, active = true }
end

function Dispatch.Close(self: Runtime, channel: Channel): ()
	if not channel.active then
		return
	end

	channel.active = false
	self.keys -= channel.latestCount
	Metrics.Adjust(channel.diagnostics, "hintLatestKeys", -channel.latestCount)
	channel.latest, channel.latestCount = {}, 0
end

function Dispatch.ForgetActor(self: Runtime, channel: Channel, actor: ActorTypes.Actor): ()
	for key, latest in channel.latest do
		if latest.actor == actor then
			channel.latest[key] = nil
			channel.latestCount -= 1
			self.keys -= 1
			Metrics.Adjust(channel.diagnostics, "hintLatestKeys", -1)
		end
	end
end

function Dispatch._authorize(
	self: Runtime,
	connection: Channel,
	record: SharedTypes.HintRecord,
	actor: ActorTypes.Actor?,
	hint: SharedTypes.ClientHint,
	definition: Types.LoadedHintDefinition
): Types.HintContext?
	local function eligible(): boolean
		return connection.current()
			and (
				record.targetHandle == nil
				or self.awareness:ResolveActor(connection.player, record.targetHandle) == actor
			)
	end

	local context = Context.new(connection.player, actor, hint.id, {
		ready = eligible,
		owns = function(): boolean
			return actor ~= nil
				and self.awareness:GetActorForPlayer(connection.player) == actor
				and self.awareness:GetPlayerForActor(actor) == connection.player
		end,
	})

	local authorize, receive = definition.authorize, definition.receive
	assert(authorize ~= nil and receive ~= nil, "Expected validated C2S callbacks")
	local completed, allowed = Context.Resume(coroutine.create(authorize), context, record.payload)

	if not completed or allowed ~= true or not eligible() then
		if not completed or allowed ~= true then
			Metrics.Count(connection.diagnostics, "hintsUnauthorized", 1)
			Metrics.Warn(connection.diagnostics, "HintAbuse", "hintsUnauthorized")
		end

		Context.Release(context)

		Metrics.Count(connection.diagnostics, "hintsDropped", 1)

		return nil
	end

	return context
end

function Dispatch.Deliver(self: Runtime, connection: Channel, record: SharedTypes.HintRecord): boolean
	if not connection.current() then
		Metrics.Count(connection.diagnostics, "hintsDropped", 1)

		return false
	end

	local hint = if self.protocol.hintsByCode ~= nil then self.protocol.hintsByCode[record.hintCode] else nil
	assert(hint ~= nil, "Expected decoded Hint definition")
	local definition = self.catalog.definitionsById[hint.id]
	local actor: ActorTypes.Actor? = nil

	if record.targetHandle ~= nil then
		actor = self.awareness:ResolveActor(connection.player, record.targetHandle)

		if actor == nil then
			Metrics.Count(connection.diagnostics, "hintsDropped", 1)

			return false
		end
	end

	local key = tostring(record.hintCode) .. ":" .. tostring(record.targetHandle or 0)
	local latest = connection.latest[key]

	if record.sequence ~= nil then
		if latest ~= nil and record.sequence <= latest.sequence then
			Metrics.Count(connection.diagnostics, "hintsStaleDropped", 1)
			Metrics.Count(connection.diagnostics, "hintsDropped", 1)

			return false
		end

		if
			latest == nil
			and (connection.latestCount >= self.limits.maxLatestKeys or self.keys >= self.limits.maxGlobalLatestKeys)
		then
			Metrics.Count(connection.diagnostics, "hintsDropped", 1)

			return false
		end
	end

	local context = self:_authorize(connection, record, actor, hint, definition)

	if context == nil then
		return false
	end

	if record.sequence ~= nil then
		if latest == nil then
			connection.latestCount += 1
			self.keys += 1
			Metrics.Adjust(connection.diagnostics, "hintLatestKeys", 1)
		end

		connection.latest[key] = { actor = actor, sequence = record.sequence }
	end

	Metrics.Count(connection.diagnostics, "hintsReceived", 1)

	local delivered = Context.Resume(
		coroutine.create(assert(definition.receive, "Expected validated C2S receiver")),
		context,
		record.payload
	)

	Context.Release(context)

	if not delivered then
		Metrics.Count(connection.diagnostics, "hintCallbackFaults", 1)
		Metrics.Warn(connection.diagnostics, "HintAbuse", "hintCallbackFaults")
	end

	return delivered
end

return Dispatch
