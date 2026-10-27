--!strict
local Types = require(script.Parent.Parent.types)
local SharedTypes = require(script.Parent.Parent.Parent.Parent.shared.Networking.types)
local Metrics = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.NetworkingMetrics)
local Diagnostics = require(script.Parent.NetworkingDiagnosticsState)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)

type Account = {
	diagnostics: SharedTypes.DiagnosticCollector?,
	records: number,
	bytes: number,
	pending: { [Charge]: boolean },
	closed: boolean,
}

type Charge = {
	release: () -> (),
	stage: () -> (),
	resume: () -> (),
	active: boolean,
	owner: Account,
	actor: Account,
	key: Types.PublicationStreamKey,
	payload: any,
	bytes: number,
}

type Payload = { references: number, bytes: number, onUnused: (() -> ())? }

type Bounds = {
	maxRecords: number,
	maxBytes: number,
	actorRecords: number,
	actorBytes: number,
	recipientRecords: number,
	recipientBytes: number,
	recoveryRecords: number,
	recoveryBytes: number,
}

type State = {
	diagnostics: SharedTypes.DiagnosticCollector?,
	maxStreamRecords: number,
	maxStreamBytes: number,
	limits: Bounds,
	baselineBytes: number,
	records: number,
	bytes: number,
	recipients: { [any]: Account },
	actors: { [any]: Account },
	payloads: { [any]: Payload },
	charges: { [Charge]: boolean },
	destroyed: boolean,
}

local ReliableBacklog = {}
ReliableBacklog.__index = ReliableBacklog

type Runtime = typeof(setmetatable({} :: State, ReliableBacklog))

local function release(self: Runtime, charge: Charge): ()
	if not charge.active then
		return
	end

	charge.active = false
	self.charges[charge], charge.owner.pending[charge] = nil, nil
	self.records -= 1
	Metrics.Adjust(charge.owner.diagnostics, "reliableRecords", -1)
	Metrics.Adjust(charge.owner.diagnostics, "reliableDeliveryBytes", -charge.bytes)
	charge.owner.records -= 1
	charge.owner.bytes -= charge.bytes
	charge.actor.records -= 1
	charge.actor.bytes -= charge.bytes

	if charge.owner.records == 0 and self.recipients[charge.key.recipient] == charge.owner then
		self.recipients[charge.key.recipient] = nil
	end

	if charge.actor.records == 0 then
		self.actors[charge.key.actor] = nil
	end

	local payload = self.payloads[charge.payload]
	payload.references -= 1

	if payload.references == 0 then
		self.payloads[charge.payload] = nil
		self.bytes -= payload.bytes
		Metrics.Adjust(self.diagnostics, "reliableRetainedBytes", -payload.bytes)

		if payload.onUnused ~= nil then
			payload.onUnused()
		end
	end

	charge.payload = nil
end

function ReliableBacklog.new(overrides: Types.ReliableBacklogLimits?, baselineBytes: number): Types.ReliableBacklog
	local options: Types.ReliableBacklogLimits = overrides or {}

	local limits: Bounds = {
		maxRecords = if options.maxRecords ~= nil then options.maxRecords else Constants.BACKLOG_RECORDS,
		maxBytes = if options.maxBytes ~= nil then options.maxBytes else Constants.BACKLOG_BYTES,
		actorRecords = if options.actorRecords ~= nil then options.actorRecords else Constants.BACKLOG_ACTOR_RECORDS,
		actorBytes = if options.actorBytes ~= nil then options.actorBytes else Constants.BACKLOG_ACTOR_BYTES,
		recipientRecords = if options.recipientRecords ~= nil
			then options.recipientRecords
			else Constants.BACKLOG_RECIPIENT_RECORDS,
		recipientBytes = if options.recipientBytes ~= nil
			then options.recipientBytes
			else Constants.BACKLOG_RECIPIENT_BYTES,
		recoveryRecords = if options.recoveryRecords ~= nil
			then options.recoveryRecords
			else Constants.BACKLOG_RECOVERY_RECORDS,
		recoveryBytes = if options.recoveryBytes ~= nil
			then options.recoveryBytes
			else Constants.BACKLOG_RECOVERY_BYTES,
	}

	for _, value in
		{
			limits.maxRecords,
			limits.maxBytes,
			limits.actorRecords,
			limits.actorBytes,
			limits.recipientRecords,
			limits.recipientBytes,
			limits.recoveryRecords,
			limits.recoveryBytes,
		}
	do
		assert(value >= 0 and value < math.huge and value % 1 == 0, "InvalidReliableBacklogLimit")
	end

	local state: State = {
		diagnostics = Diagnostics.GetServer(),
		-- One blocked recipient/Actor cannot fill the whole Actor allowance.
		maxStreamRecords = math.max(0, math.floor((limits.actorRecords - 1) / 4)),
		maxStreamBytes = math.max(0, math.floor((limits.actorBytes - baselineBytes) / 4)),
		limits = limits,
		baselineBytes = baselineBytes,
		records = 0,
		bytes = 0,
		recipients = {},
		actors = {},
		payloads = {},
		charges = {},
		destroyed = false,
	}

	return setmetatable(state, ReliableBacklog) :: Types.ReliableBacklog
end

function ReliableBacklog.Acquire(
	self: Runtime,
	key: Types.PublicationStreamKey,
	payload: any,
	bytes: number,
	previous: Types.PublicationCharge?,
	baseline: boolean?,
	onUnused: (() -> ())?,
	reuseQueued: boolean?
): Types.PublicationCharge?
	if self.destroyed then
		return nil
	end

	local earlier = previous :: Charge?

	if earlier ~= nil and not earlier.active then
		earlier = nil
	end

	if earlier ~= nil then
		assert(
			self.charges[earlier] and earlier.key.recipient == key.recipient and earlier.key.actor == key.actor,
			"InvalidReliableBacklogReplacement"
		)

		-- A staged lease belongs to the pump, even if a caller offers it as a
		-- queued-state replacement. Admit independently without releasing that lease.
		if earlier.owner.pending[earlier] ~= true then
			earlier = nil
		elseif earlier.payload == payload then
			return earlier
		end
	end

	local retained = self.payloads[payload]
	assert(retained == nil or retained.bytes == bytes, "ReliableBacklogPayloadChanged")
	local oldPayload = if earlier ~= nil then self.payloads[earlier.payload] else nil
	local owner: Account? = self.recipients[key.recipient]
	local actor: Account? = self.actors[key.actor]
	local count = if earlier ~= nil then 0 else 1
	local localBytes = bytes - (if earlier ~= nil then earlier.bytes else 0)
	local added = if retained == nil then bytes else 0
	local removed = if oldPayload ~= nil and oldPayload.references == 1 then oldPayload.bytes else 0
	local limits = self.limits
	local recordReserve = if baseline then 0 else limits.recoveryRecords
	local byteReserve = if baseline then 0 else limits.recoveryBytes
	local localRecordReserve = if baseline then 0 else 1
	local localByteReserve = if baseline then 0 else self.baselineBytes

	-- Reserved capacity restricts growth, not a tail replacement that frees space.
	if
		(count > 0 and self.records + count > limits.maxRecords - recordReserve)
		or (added > removed and self.bytes + added - removed > limits.maxBytes - byteReserve)
		or (count > 0 and (if owner ~= nil then owner.records else 0) + count > limits.recipientRecords - localRecordReserve)
		or (localBytes > 0 and (if owner ~= nil then owner.bytes else 0) + localBytes > limits.recipientBytes - localByteReserve)
		or (count > 0 and (if actor ~= nil then actor.records else 0) + count > limits.actorRecords - localRecordReserve)
		or (
			localBytes > 0
			and (if actor ~= nil then actor.bytes else 0) + localBytes > limits.actorBytes - localByteReserve
		)
	then
		Metrics.Count(
			if owner ~= nil
				then owner.diagnostics
				else (if self.diagnostics ~= nil then Diagnostics.GetConnection(key.recipient) else nil),
			"reliableChargesRefused",
			1
		)

		return nil
	end

	if
		reuseQueued
		and not baseline
		and earlier ~= nil
		and oldPayload ~= nil
		and (oldPayload.references > 1 or oldPayload.onUnused == nil)
	then
		-- All independent limits were checked above. Keep the queued lease and
		-- its indexes/closures; only payload references and byte liabilities change.
		-- A final-use callback remains on the original path, outside this fast path.
		if retained == nil then
			retained = { references = 0, bytes = bytes, onUnused = onUnused }
			self.payloads[payload] = retained
		end

		retained.references += 1
		oldPayload.references -= 1

		if oldPayload.references == 0 then
			self.payloads[earlier.payload] = nil
		end

		self.bytes += added - removed
		earlier.owner.bytes += localBytes
		earlier.actor.bytes += localBytes
		earlier.payload, earlier.bytes = payload, bytes
		Metrics.Count(earlier.owner.diagnostics, "reliableChargesAdmitted", 1)

		if added ~= removed then
			Metrics.Adjust(self.diagnostics, "reliableRetainedBytes", added - removed)
		end

		if localBytes ~= 0 then
			Metrics.Adjust(earlier.owner.diagnostics, "reliableDeliveryBytes", localBytes)
		end

		return earlier
	end

	if earlier ~= nil then
		release(self, earlier)
	end

	-- Replacement may have released the last charge for either account.
	owner, actor = self.recipients[key.recipient], self.actors[key.actor]

	if owner == nil then
		owner = {
			diagnostics = if self.diagnostics ~= nil then Diagnostics.GetConnection(key.recipient) else nil,
			records = 0,
			bytes = 0,
			pending = {},
			closed = false,
		}

		self.recipients[key.recipient] = owner
	end

	if actor == nil then
		local created: Account = { diagnostics = nil, records = 0, bytes = 0, pending = {}, closed = false }
		actor = created
		self.actors[key.actor] = actor
	end

	retained = self.payloads[payload]

	if retained == nil then
		retained = { references = 0, bytes = bytes, onUnused = onUnused }
		self.payloads[payload] = retained
		self.bytes += bytes
		Metrics.Adjust(self.diagnostics, "reliableRetainedBytes", bytes)
	end

	assert(retained.bytes == bytes, "ReliableBacklogPayloadChanged")
	retained.references += 1
	self.records += 1
	Metrics.Count(owner.diagnostics, "reliableChargesAdmitted", 1)
	Metrics.Adjust(owner.diagnostics, "reliableRecords", 1)
	Metrics.Adjust(owner.diagnostics, "reliableDeliveryBytes", bytes)
	owner.records += 1
	owner.bytes += bytes
	actor.records += 1
	actor.bytes += bytes

	local charge: Charge
	local recipientAccount: Account = owner

	charge = {
		owner = owner,
		actor = actor,
		key = key,
		payload = payload,
		bytes = bytes,
		active = true,
		release = function(): ()
			release(self, charge)
		end,
		stage = function(): ()
			recipientAccount.pending[charge] = nil
		end,
		resume = function(): ()
			if not charge.active then
				return
			end

			if recipientAccount.closed then
				release(self, charge)
			else
				recipientAccount.pending[charge] = true
			end
		end,
	}

	owner.pending[charge], self.charges[charge] = true, true

	return charge
end

function ReliableBacklog.CloseRecipient(self: Runtime, recipient: any): ()
	local owner = self.recipients[recipient]

	if owner == nil then
		return
	end

	self.recipients[recipient] = nil
	owner.closed = true

	-- Only charged queued work is visited, at most recipientRecords entries.
	-- Staged charges survive until their original pump unwinds, even on re-Ready.
	for charge in owner.pending do
		release(self, charge)
	end
end

function ReliableBacklog.Destroy(self: Runtime): ()
	self.destroyed = true

	for charge in self.charges do
		release(self, charge)
	end
end

return ReliableBacklog
