--!strict
local Types = require(script.Parent.Parent.types)
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.ActorProtocolConstants)

type Account = { records: number, bytes: number, pending: { [Charge]: boolean }, closed: boolean }

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

type State = {
	maxStreamRecords: number,
	maxStreamBytes: number,
	limits: { [string]: number },
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

		if payload.onUnused ~= nil then
			payload.onUnused()
		end
	end

	charge.payload = nil
end

function ReliableBacklog.new(overrides: Types.ReliableBacklogLimits?, baselineBytes: number): Types.ReliableBacklog
	local limits = {
		maxRecords = Constants.BACKLOG_RECORDS,
		maxBytes = Constants.BACKLOG_BYTES,
		actorRecords = Constants.BACKLOG_ACTOR_RECORDS,
		actorBytes = Constants.BACKLOG_ACTOR_BYTES,
		recipientRecords = Constants.BACKLOG_RECIPIENT_RECORDS,
		recipientBytes = Constants.BACKLOG_RECIPIENT_BYTES,
		recoveryRecords = Constants.BACKLOG_RECOVERY_RECORDS,
		recoveryBytes = Constants.BACKLOG_RECOVERY_BYTES,
	}

	for key, value in limits do
		limits[key] = if overrides ~= nil and overrides[key] ~= nil then overrides[key] else value
		assert(limits[key] >= 0 and limits[key] < math.huge and limits[key] % 1 == 0, "InvalidReliableBacklogLimit")
	end

	local state: State = {
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
	onUnused: (() -> ())?
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

		if earlier.payload == payload then
			return earlier
		end
	end

	local owner: Account? = self.recipients[key.recipient]
	local actor: Account? = self.actors[key.actor]
	local count = if earlier ~= nil then 0 else 1
	local localBytes = bytes - (if earlier ~= nil then earlier.bytes else 0)
	local added = if self.payloads[payload] == nil then bytes else 0
	local removed = if earlier ~= nil and self.payloads[earlier.payload].references == 1 then earlier.bytes else 0
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
		return nil
	end

	if earlier ~= nil then
		release(self, earlier)
	end

	-- Replacement may have released the last charge for either account.
	owner, actor = self.recipients[key.recipient], self.actors[key.actor]

	if owner == nil then
		owner = { records = 0, bytes = 0, pending = {}, closed = false }
		self.recipients[key.recipient] = owner
	end

	if actor == nil then
		actor = { records = 0, bytes = 0, pending = {}, closed = false }
		self.actors[key.actor] = actor
	end

	local retained = self.payloads[payload]

	if retained == nil then
		retained = { references = 0, bytes = bytes, onUnused = onUnused }
		self.payloads[payload] = retained
		self.bytes += bytes
	end

	assert(retained.bytes == bytes, "ReliableBacklogPayloadChanged")
	retained.references += 1
	self.records += 1
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
