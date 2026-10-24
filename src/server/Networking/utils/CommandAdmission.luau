--!strict
-- Protected opportunities and a shared borrowing pool, not a second job queue.
-- Queue tickets stay with the existing FIFO/dispatch owner. Membership, window
-- rotation and admission are O(1); no Ready roster scan occurs on ingress.
-- Byte bands fit the largest compiled request. If the roster exceeds protected
-- slots, aligned bands rotate, without evicting or refunding admitted work.
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)

type Member = {
	player: Player,
	index: number,
	epoch: number,
	attempts: number,
	attemptBytes: number,
	queued: number,
	queuedBytes: number,
}

export type Ticket = {
	member: Member,
	bytes: number,
	protectedCount: boolean,
	protectedBytes: boolean,
	released: boolean,
}

type Budget = { count: number, bytes: number, reservedCount: number, reservedBytes: number }

type State = {
	members: { Member },
	byPlayer: { [Player]: Member },
	rate: Budget,
	queue: Budget,
	maximumRequest: number,
	windowSeconds: number,
	window: number,
	epoch: number,
	cursor: number,
	attempts: number,
	attemptBytes: number,
	protectedAttempts: number,
	protectedAttemptBytes: number,
	protectedQueued: number,
	protectedQueuedBytes: number,
}

local CommandAdmission = {}
CommandAdmission.__index = CommandAdmission

type Admission = typeof(setmetatable({} :: State, CommandAdmission))

export type Runtime = Admission

local function budget(count: number, bytes: number, maximumRequest: number): Budget
	return {
		count = count,
		bytes = bytes,
		reservedCount = math.min(count, math.max(1, math.floor(count / Constants.ADMISSION_RESERVE_DIVISOR))),
		reservedBytes = math.min(
			bytes,
			maximumRequest * math.max(1, math.ceil(bytes / Constants.ADMISSION_RESERVE_DIVISOR / maximumRequest))
		),
	}
end

function CommandAdmission.Ready(self: Admission, player: Player): ()
	if self.byPlayer[player] ~= nil then
		return
	end

	local member: Member = {
		player = player,
		index = #self.members + 1,
		epoch = -1,
		attempts = 0,
		attemptBytes = 0,
		queued = 0,
		queuedBytes = 0,
	}

	self.byPlayer[player] = member
	table.insert(self.members, member)
	-- Newcomers join the protected band without revoking existing charges.
	self.cursor = member.index - 1
end

function CommandAdmission.Closed(self: Admission, player: Player): ()
	local member = self.byPlayer[player]

	if member == nil then
		return
	end

	local tail = table.remove(self.members) :: Member

	if tail ~= member then
		self.members[member.index] = tail
		tail.index = member.index
	end

	self.byPlayer[player] = nil
	self.cursor %= math.max(1, #self.members)
	-- Window charges are not refunded. Outstanding tickets retain this member
	-- until their single queue/dispatch owner releases them.
end

function CommandAdmission._slots(self: Admission, capacity: number, bytes: boolean): number
	if capacity == 0 then
		return 0
	end

	local slots = if bytes then math.max(1, math.floor(capacity / self.maximumRequest)) else capacity

	return math.min(#self.members, slots)
end

function CommandAdmission._quota(self: Admission, member: Member, capacity: number, bytes: boolean): number
	local slots = self:_slots(capacity, bytes)

	if slots == 0 or (member.index - 1 - self.cursor) % #self.members >= slots then
		return 0
	end

	local position = (member.index - 1 - self.cursor) % #self.members

	return math.floor(capacity / slots) + (if position < capacity % slots then 1 else 0)
end

function CommandAdmission.Advance(self: Admission, now: number): ()
	if now - self.window < self.windowSeconds then
		return
	end

	local steps = if self.windowSeconds > 0
		then math.max(1, math.floor((now - self.window) / self.windowSeconds))
		else 1

	local band = math.max(
		1,
		math.min(
			self:_slots(self.rate.reservedCount, false),
			self:_slots(self.rate.reservedBytes, true),
			self:_slots(self.queue.reservedCount, false),
			self:_slots(self.queue.reservedBytes, true)
		)
	)

	self.cursor = (self.cursor + steps * band) % math.max(1, #self.members)
	self.window = if self.windowSeconds > 0 then self.window + steps * self.windowSeconds else now
	self.epoch += steps
	self.attempts, self.attemptBytes = 0, 0
	self.protectedAttempts, self.protectedAttemptBytes = 0, 0
end

local function choose(
	limit: number,
	used: number,
	reserved: number,
	protectedUsed: number,
	own: number,
	quota: number,
	amount: number
): (boolean, boolean)
	if amount > limit - used then
		return false, false
	end

	if amount <= quota - own and amount <= reserved - protectedUsed then
		return true, true
	end

	return amount <= limit - reserved - (used - protectedUsed), false
end

function CommandAdmission.Attempt(self: Admission, player: Player, bytes: number, now: number): boolean
	self:Advance(now)
	self:Ready(player)
	local member = self.byPlayer[player]

	if member.epoch ~= self.epoch then
		member.epoch, member.attempts, member.attemptBytes = self.epoch, 0, 0
	end

	local rate = self.rate

	local countAllowed, protectedCount = choose(
		rate.count,
		self.attempts,
		rate.reservedCount,
		self.protectedAttempts,
		member.attempts,
		self:_quota(member, rate.reservedCount, false),
		1
	)

	local bytesAllowed, protectedBytes = choose(
		rate.bytes,
		self.attemptBytes,
		rate.reservedBytes,
		self.protectedAttemptBytes,
		member.attemptBytes,
		self:_quota(member, rate.reservedBytes, true),
		bytes
	)

	if not countAllowed or not bytesAllowed then
		return false
	end

	self.attempts += 1
	self.attemptBytes += bytes

	if protectedCount then
		self.protectedAttempts += 1
		member.attempts += 1
	end

	if protectedBytes then
		self.protectedAttemptBytes += bytes
		member.attemptBytes += bytes
	end

	return true
end

function CommandAdmission.Queue(
	self: Admission,
	player: Player,
	bytes: number,
	used: number,
	usedBytes: number
): Ticket?
	local member = self.byPlayer[player]
	local queue = self.queue

	local countAllowed, protectedCount = choose(
		queue.count,
		used,
		queue.reservedCount,
		self.protectedQueued,
		member.queued,
		self:_quota(member, queue.reservedCount, false),
		1
	)

	local bytesAllowed, protectedBytes = choose(
		queue.bytes,
		usedBytes,
		queue.reservedBytes,
		self.protectedQueuedBytes,
		member.queuedBytes,
		self:_quota(member, queue.reservedBytes, true),
		bytes
	)

	if not countAllowed or not bytesAllowed then
		return nil
	end

	if protectedCount then
		self.protectedQueued += 1
		member.queued += 1
	end

	if protectedBytes then
		self.protectedQueuedBytes += bytes
		member.queuedBytes += bytes
	end

	return {
		member = member,
		bytes = bytes,
		protectedCount = protectedCount,
		protectedBytes = protectedBytes,
		released = false,
	}
end

function CommandAdmission.Release(self: Admission, ticket: Ticket): ()
	assert(not ticket.released, "CommandAdmissionTicketReleased")
	ticket.released = true

	if ticket.protectedCount then
		self.protectedQueued -= 1
		ticket.member.queued -= 1
	end

	if ticket.protectedBytes then
		self.protectedQueuedBytes -= ticket.bytes
		ticket.member.queuedBytes -= ticket.bytes
	end
end

function CommandAdmission.Destroy(self: Admission): ()
	table.clear(self.members)
	table.clear(self.byPlayer)
end

function CommandAdmission.new(
	requests: number,
	bytes: number,
	queued: number,
	queuedBytes: number,
	maximumRequest: number,
	windowSeconds: number,
	now: number
): Admission
	local state: State = {
		members = {},
		byPlayer = {},
		rate = budget(requests, bytes, maximumRequest),
		queue = budget(queued, queuedBytes, maximumRequest),
		maximumRequest = maximumRequest,
		windowSeconds = windowSeconds,
		window = now,
		epoch = 0,
		cursor = 0,
		attempts = 0,
		attemptBytes = 0,
		protectedAttempts = 0,
		protectedAttemptBytes = 0,
		protectedQueued = 0,
		protectedQueuedBytes = 0,
	}

	return setmetatable(state, CommandAdmission)
end

return CommandAdmission
