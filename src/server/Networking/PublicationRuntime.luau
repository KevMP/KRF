--!strict
local PublicationTypes = require(script.Parent.PublicationTypes)
local PublicationCapture = require(script.Parent.PublicationCapture)
local ReplicationTypes = require(script.Parent.Parent.Replication.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local SchemaCollectionUtils = require(script.Parent.Parent.Parent.shared.Networking.utils.SchemaCollectionUtils)

local PublicationRuntime = {}
PublicationRuntime.__index = PublicationRuntime

type Attachment = {
	sequence: number,
	captures: { [string]: PublicationTypes.CaptureResult },
	disconnects: { { domainId: string, callback: () -> () } },
	active: boolean,
	depth: number,
	touched: { [string]: boolean },
	events: { PublicationTypes.Event },
	poisoned: boolean,
}

local function runSync(callback: () -> ...any): (boolean, string, ...any)
	local thread = coroutine.create(callback)
	local success, first, second = coroutine.resume(thread)
	if not success then
		return false, "Error", first
	end
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		return false, "Yielded"
	end
	return true, "", first, second
end

local function fault(self: any, actor: ActorTypes.Actor, domainId: string, reason: string): ()
	if self.options ~= nil and self.options.ReportFault ~= nil then
		pcall(self.options.ReportFault, { actorId = actor:GetId(), domainId = domainId, reason = reason })
	end
end

local function eventsFor(
	self: any,
	actor: ActorTypes.Actor,
	attachment: Attachment,
	domainId: string,
	reported: any
): ()
	if reported == nil then
		return
	end
	local definitions = self.eventsByDomain[domainId]
	local stagedEvents: { PublicationTypes.Event } = {}
	local count: number? = SchemaCollectionUtils.GetArrayLength(reported)
	if count == nil then
		if attachment.depth > 0 then
			attachment.poisoned = true
		end
		fault(self, actor, domainId, "InvalidPublicationEvent")
		error("InvalidPublicationEvent:" .. domainId, 0)
	end
	for index: number = 1, count do
		local event: any = rawget(reported, index)
		local plan = if type(event) == "table" then definitions[event.id] else nil
		local captured = if plan ~= nil then plan:Capture(event.payload, nil) else nil
		if captured == nil then
			if attachment.depth > 0 then
				attachment.poisoned = true
			end
			fault(self, actor, domainId, "InvalidPublicationEvent")
			error("InvalidPublicationEvent:" .. domainId, 0)
		end
		table.insert(
			stagedEvents,
			table.freeze({
				domainId = domainId,
				eventId = event.id,
				payload = captured.value,
			})
		)
	end
	for _, event in stagedEvents do
		table.insert(attachment.events, event)
	end
end

local function captureDomain(
	self: any,
	actor: ActorTypes.Actor,
	domain: ReplicationTypes.LoadedReplicationDomainDefinition,
	previous: PublicationTypes.CaptureResult?
): PublicationTypes.CaptureResult
	local ok, kind, value = runSync(function(): any
		return domain.snapshot(actor)
	end)
	if not ok then
		local reason = "PublicationSnapshot" .. kind
		fault(self, actor, domain.id, reason)
		error(reason .. ":" .. domain.id, 0)
	end
	local captured = self.plans[domain.id]:Capture(value, previous)
	if captured == nil then
		fault(self, actor, domain.id, "InvalidPublicationSnapshot")
		error("InvalidPublicationSnapshot:" .. domain.id, 0)
	end
	return captured
end

local function dispatchCommits(self: any): ()
	if self.dispatching then
		return
	end
	self.dispatching = true
	local failed = false
	local failure: any = nil
	while #self.pendingCommits > 0 and not self.destroyed do
		local commit: PublicationTypes.Commit = table.remove(self.pendingCommits, 1) :: PublicationTypes.Commit
		for _, observer in table.clone(self.observers) do
			if self.destroyed then
				break
			end
			local success, reason = pcall(observer, commit)
			if not success and not failed then
				failed = true
				failure = reason
			end
		end
	end
	self.dispatching = false
	if failed then
		error(failure, 0)
	end
end

local function publish(self: any, actor: ActorTypes.Actor, attachment: Attachment): ()
	local touched = attachment.touched
	local events = attachment.events
	attachment.touched = {}
	attachment.events = {}
	local staged: { [string]: PublicationTypes.CaptureResult } = {}
	local patches: { PublicationTypes.DomainPatch } = {}
	for _, domain in self.domains do
		if touched[domain.id] then
			local captured = captureDomain(self, actor, domain, attachment.captures[domain.id])
			staged[domain.id] = captured
			if captured.patch ~= nil then
				table.insert(patches, table.freeze({ domainId = domain.id, patch = captured.patch }))
			end
		end
	end
	if #patches == 0 and #events == 0 then
		return
	end
	for domainId, captured in staged do
		attachment.captures[domainId] = captured
	end
	attachment.sequence += 1
	local commit = table.freeze({
		actor = actor,
		sequence = attachment.sequence,
		patches = table.freeze(patches),
		events = table.freeze(events),
	})
	table.insert(self.pendingCommits, commit)
	dispatchCommits(self)
end

function PublicationRuntime.new(
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	options: PublicationTypes.RuntimeOptions?
): PublicationTypes.Runtime
	local domains = table.clone(catalog.orderedDefinitions)
	table.sort(
		domains,
		function(
			a: ReplicationTypes.LoadedReplicationDomainDefinition,
			b: ReplicationTypes.LoadedReplicationDomainDefinition
		): boolean
			return a.id < b.id
		end
	)
	local plans: { [string]: PublicationTypes.CapturePlan } = {}
	local eventsByDomain: { [string]: { [string]: PublicationTypes.CapturePlan } } = {}
	for _, domain in domains do
		plans[domain.id] = PublicationCapture.Compile(domain.state)
		local eventPlans: { [string]: PublicationTypes.CapturePlan } = {}
		for _, event in domain.events do
			eventPlans[event.id] = PublicationCapture.Compile(event.payload)
		end
		eventsByDomain[domain.id] = eventPlans
	end
	return setmetatable({
		domains = domains,
		plans = plans,
		eventsByDomain = eventsByDomain,
		options = options,
		attachments = {},
		orderedActors = {},
		observers = {},
		pendingCommits = {},
		dispatching = false,
		destroyed = false,
	}, PublicationRuntime) :: any
end

function PublicationRuntime.ValidateEventBounds(
	catalog: ReplicationTypes.PreparedReplicationDomainCatalog,
	maxEventBytes: number
): (boolean, string?)
	for _, domain in catalog.orderedDefinitions do
		for _, event in domain.events do
			if event.payload.maxEncodedBytes > maxEventBytes then
				return false, "PublicationEventTooLarge:" .. domain.id .. ":" .. event.id
			end
		end
	end
	return true, nil
end

function PublicationRuntime.AttachActor(self: any, actor: ActorTypes.Actor): (boolean, string?)
	if self.destroyed then
		return false, "PublicationRuntimeDestroyed"
	end
	if self.attachments[actor] ~= nil then
		return true, nil
	end
	local attachment: Attachment = {
		sequence = 0,
		captures = {},
		disconnects = {},
		active = true,
		depth = 0,
		touched = {},
		events = {},
		poisoned = false,
	}
	local success, failure = pcall(function()
		for _, domain in self.domains do
			attachment.captures[domain.id] = captureDomain(self, actor, domain, nil)
			if domain.observe ~= nil then
				local ok, kind, disconnect = runSync(function(): (() -> ())?
					return domain.observe(actor, function(reported: { ReplicationTypes.ReplicationDomainEvent }?): ()
						if not attachment.active then
							return
						end
						eventsFor(self, actor, attachment, domain.id, reported)
						attachment.touched[domain.id] = true
						if attachment.depth == 0 then
							publish(self, actor, attachment)
						end
					end)
				end)
				if not ok then
					error("PublicationObserve" .. kind .. ":" .. domain.id, 0)
				end
				if disconnect ~= nil then
					table.insert(attachment.disconnects, { domainId = domain.id, callback = disconnect })
				end
			end
		end
	end)
	if not success then
		attachment.active = false
		for _, connection in attachment.disconnects do
			pcall(connection.callback)
		end
		return false, tostring(failure)
	end
	self.attachments[actor] = attachment
	table.insert(self.orderedActors, actor)
	return true, nil
end

function PublicationRuntime.DetachActor(self: any, actor: ActorTypes.Actor): ()
	local attachment: Attachment? = self.attachments[actor]
	if attachment == nil then
		return
	end
	self.attachments[actor] = nil
	attachment.active = false
	for index, attachedActor in self.orderedActors do
		if attachedActor == actor then
			table.remove(self.orderedActors, index)
			break
		end
	end
	for _, connection in attachment.disconnects do
		if not pcall(connection.callback) then
			fault(self, actor, connection.domainId, "PublicationDisconnectError")
		end
	end
end

function PublicationRuntime.GetActorSequence(self: any, actor: ActorTypes.Actor): number
	local attachment: Attachment? = self.attachments[actor]
	return if attachment == nil then 0 else attachment.sequence
end

function PublicationRuntime.GetAttachedActors(self: any): { ActorTypes.Actor }
	return table.clone(self.orderedActors)
end

function PublicationRuntime.CaptureBaseline(self: any, actor: ActorTypes.Actor): PublicationTypes.Baseline?
	local attachment: Attachment? = self.attachments[actor]
	if attachment == nil then
		return nil
	end
	local domains: { [string]: PublicationTypes.DomainTruth } = {}
	for domainId, captured in attachment.captures do
		domains[domainId] = table.freeze({ value = captured.value })
	end
	return table.freeze({ sequence = attachment.sequence, domains = table.freeze(domains) })
end

function PublicationRuntime.ObserveCommits(self: any, observer: (PublicationTypes.Commit) -> ()): () -> ()
	table.insert(self.observers, observer)
	local active = true
	return function(): ()
		if not active then
			return
		end
		active = false
		for index, existing in self.observers do
			if existing == observer then
				table.remove(self.observers, index)
				break
			end
		end
	end
end

function PublicationRuntime.WithActorCommit(self: any, actor: ActorTypes.Actor, callback: () -> ()): ()
	local attachment: Attachment? = self.attachments[actor]
	if attachment == nil then
		local ok, kind, failure = runSync(callback)
		if not ok then
			error(if kind == "Yielded" then "PublicationCommitYielded" else failure, 0)
		end
		return
	end
	attachment.depth += 1
	local ok, kind, failure = runSync(callback)
	attachment.depth -= 1
	if attachment.depth == 0 then
		if attachment.poisoned then
			attachment.touched = {}
			attachment.events = {}
			attachment.poisoned = false
		else
			publish(self, actor, attachment)
		end
	end
	if not ok then
		error(if kind == "Yielded" then "PublicationCommitYielded" else failure, 0)
	end
end

function PublicationRuntime.Destroy(self: any): ()
	if self.destroyed then
		return
	end
	self.destroyed = true
	table.clear(self.pendingCommits)
	for _, actor in table.clone(self.orderedActors) do
		self:DetachActor(actor)
	end
	table.clear(self.observers)
end

return PublicationRuntime
