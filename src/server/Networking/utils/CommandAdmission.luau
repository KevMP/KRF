--!strict
-- Protected opportunities and a shared borrowing pool, not a second job queue.
-- Queue tickets stay with the existing FIFO/dispatch owner. Membership, window
-- rotation and admission are O(1); no Ready roster scan occurs on ingress.
-- Byte bands fit the largest compiled request. If the roster exceeds protected
-- slots, aligned bands rotate, without evicting or refunding admitted work.
-- When framework follow-ups exist, a further bounded reserve is kept out of the
-- shared pool for them only. Each member may hold a small share of it, so one
-- connection cannot spend the whole reserve, and nothing exceeds a global total.
local Constants = require(script.Parent.Parent.Parent.Parent.shared.Networking.utils.CommandConstants)

type Member = {
	player: Player,
	index: number,
	epoch: number,
	attempts: number,
	attemptBytes: number,
	queued: number,
	queuedBytes: number,
	followUpAttempts: number,
	followUpAttemptBytes: number,
	followUpQueued: number,
	followUpQueuedBytes: number,
}

-- Which reserve one dimension of an admitted request is charged to.
type Lane = "Band" | "FollowUp" | "Shared"

export type Ticket = {
	member: Member,
	bytes: number,
	countLane: Lane,
	bytesLane: Lane,
	released: boolean,
}

type Budget = {
	count: number,
	bytes: number,
	reservedCount: number,
	reservedBytes: number,
	followUpCount: number,
	followUpBytes: number,
	memberFollowUpCount: number,
	memberFollowUpBytes: number,
}

type Usage = {
	used: number,
	protectedUsed: number,
	own: number,
	quota: number,
	followUpUsed: number,
	followUpOwn: number,
}

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
	followUpAttempts: number,
	followUpAttemptBytes: number,
	followUpQueued: number,
	followUpQueuedBytes: number,
}

local CommandAdmission = {}
CommandAdmission.__index = CommandAdmission

type Admission = typeof(setmetatable({} :: State, CommandAdmission))

export type Runtime = Admission

local function budget(count: number, bytes: number, maximumRequest: number, maximumFollowUp: number?): Budget
	local reservedCount: number = math.min(count, math.max(1, math.floor(count / Constants.ADMISSION_RESERVE_DIVISOR)))

	local reservedBytes: number = math.min(
		bytes,
		maximumRequest * math.max(1, math.ceil(bytes / Constants.ADMISSION_RESERVE_DIVISOR / maximumRequest))
	)

	local followUpCount: number = 0
	local followUpBytes: number = 0

	if maximumFollowUp ~= nil then
		followUpCount =
			math.min(count - reservedCount, math.max(1, math.floor(count / Constants.FOLLOW_UP_RESERVE_DIVISOR)))

		followUpBytes = math.min(
			bytes - reservedBytes,
			math.max(maximumFollowUp, math.floor(bytes / Constants.FOLLOW_UP_RESERVE_DIVISOR))
		)
	end

	return {
		count = count,
		bytes = bytes,
		reservedCount = reservedCount,
		reservedBytes = reservedBytes,
		followUpCount = followUpCount,
		followUpBytes = followUpBytes,
		memberFollowUpCount = math.min(
			followUpCount,
			math.max(1, math.floor(followUpCount / Constants.FOLLOW_UP_MEMBER_DIVISOR))
		),
		memberFollowUpBytes = math.min(
			followUpBytes,
			math.max(maximumFollowUp or 0, math.floor(followUpBytes / Constants.FOLLOW_UP_MEMBER_DIVISOR))
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
		followUpAttempts = 0,
		followUpAttemptBytes = 0,
		followUpQueued = 0,
		followUpQueuedBytes = 0,
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
	self.followUpAttempts, self.followUpAttemptBytes = 0, 0
end

-- Band protection first, then the shared pool, then the follow-up reserve. With
-- no follow-up reserve this is exactly the band/shared policy.
local function choose(
	budgetLimit: number,
	reserved: number,
	followUp: number,
	memberFollowUp: number,
	usage: Usage,
	amount: number,
	isFollowUp: boolean
): Lane?
	if amount > budgetLimit - usage.used then
		return nil
	end

	if amount <= usage.quota - usage.own and amount <= reserved - usage.protectedUsed then
		return "Band"
	end

	if amount <= budgetLimit - reserved - followUp - (usage.used - usage.protectedUsed - usage.followUpUsed) then
		return "Shared"
	end

	if isFollowUp and amount <= followUp - usage.followUpUsed and amount <= memberFollowUp - usage.followUpOwn then
		return "FollowUp"
	end

	return nil
end

function CommandAdmission.Attempt(
	self: Admission,
	player: Player,
	bytes: number,
	now: number,
	followUp: boolean
): boolean
	self:Advance(now)
	self:Ready(player)
	local member = self.byPlayer[player]

	if member.epoch ~= self.epoch then
		member.epoch, member.attempts, member.attemptBytes = self.epoch, 0, 0
		member.followUpAttempts, member.followUpAttemptBytes = 0, 0
	end

	local rate = self.rate

	local countLane: Lane? = choose(rate.count, rate.reservedCount, rate.followUpCount, rate.memberFollowUpCount, {
		used = self.attempts,
		protectedUsed = self.protectedAttempts,
		own = member.attempts,
		quota = self:_quota(member, rate.reservedCount, false),
		followUpUsed = self.followUpAttempts,
		followUpOwn = member.followUpAttempts,
	}, 1, followUp)

	local bytesLane: Lane? = choose(rate.bytes, rate.reservedBytes, rate.followUpBytes, rate.memberFollowUpBytes, {
		used = self.attemptBytes,
		protectedUsed = self.protectedAttemptBytes,
		own = member.attemptBytes,
		quota = self:_quota(member, rate.reservedBytes, true),
		followUpUsed = self.followUpAttemptBytes,
		followUpOwn = member.followUpAttemptBytes,
	}, bytes, followUp)

	if countLane == nil or bytesLane == nil then
		return false
	end

	self.attempts += 1
	self.attemptBytes += bytes

	if countLane == "Band" then
		self.protectedAttempts += 1
		member.attempts += 1
	elseif countLane == "FollowUp" then
		self.followUpAttempts += 1
		member.followUpAttempts += 1
	end

	if bytesLane == "Band" then
		self.protectedAttemptBytes += bytes
		member.attemptBytes += bytes
	elseif bytesLane == "FollowUp" then
		self.followUpAttemptBytes += bytes
		member.followUpAttemptBytes += bytes
	end

	return true
end

function CommandAdmission.Queue(
	self: Admission,
	player: Player,
	bytes: number,
	used: number,
	usedBytes: number,
	followUp: boolean
): Ticket?
	local member = self.byPlayer[player]
	local queue = self.queue

	local countLane: Lane? = choose(queue.count, queue.reservedCount, queue.followUpCount, queue.memberFollowUpCount, {
		used = used,
		protectedUsed = self.protectedQueued,
		own = member.queued,
		quota = self:_quota(member, queue.reservedCount, false),
		followUpUsed = self.followUpQueued,
		followUpOwn = member.followUpQueued,
	}, 1, followUp)

	local bytesLane: Lane? = choose(queue.bytes, queue.reservedBytes, queue.followUpBytes, queue.memberFollowUpBytes, {
		used = usedBytes,
		protectedUsed = self.protectedQueuedBytes,
		own = member.queuedBytes,
		quota = self:_quota(member, queue.reservedBytes, true),
		followUpUsed = self.followUpQueuedBytes,
		followUpOwn = member.followUpQueuedBytes,
	}, bytes, followUp)

	if countLane == nil or bytesLane == nil then
		return nil
	end

	if countLane == "Band" then
		self.protectedQueued += 1
		member.queued += 1
	elseif countLane == "FollowUp" then
		self.followUpQueued += 1
		member.followUpQueued += 1
	end

	if bytesLane == "Band" then
		self.protectedQueuedBytes += bytes
		member.queuedBytes += bytes
	elseif bytesLane == "FollowUp" then
		self.followUpQueuedBytes += bytes
		member.followUpQueuedBytes += bytes
	end

	return {
		member = member,
		bytes = bytes,
		countLane = countLane,
		bytesLane = bytesLane,
		released = false,
	}
end

function CommandAdmission.Release(self: Admission, ticket: Ticket): ()
	assert(not ticket.released, "CommandAdmissionTicketReleased")
	ticket.released = true

	if ticket.countLane == "Band" then
		self.protectedQueued -= 1
		ticket.member.queued -= 1
	elseif ticket.countLane == "FollowUp" then
		self.followUpQueued -= 1
		ticket.member.followUpQueued -= 1
	end

	if ticket.bytesLane == "Band" then
		self.protectedQueuedBytes -= ticket.bytes
		ticket.member.queuedBytes -= ticket.bytes
	elseif ticket.bytesLane == "FollowUp" then
		self.followUpQueuedBytes -= ticket.bytes
		ticket.member.followUpQueuedBytes -= ticket.bytes
	end
end

function CommandAdmission.Destroy(self: Admission): ()
	table.clear(self.members)
	table.clear(self.byPlayer)
end

-- maximumFollowUp is the largest follow-up request in bytes, or nil when the
-- protocol classifies no follow-ups and therefore keeps no follow-up reserve.
function CommandAdmission.new(
	requests: number,
	bytes: number,
	queued: number,
	queuedBytes: number,
	maximumRequest: number,
	windowSeconds: number,
	now: number,
	maximumFollowUp: number?
): Admission
	local state: State = {
		members = {},
		byPlayer = {},
		rate = budget(requests, bytes, maximumRequest, maximumFollowUp),
		queue = budget(queued, queuedBytes, maximumRequest, maximumFollowUp),
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
		followUpAttempts = 0,
		followUpAttemptBytes = 0,
		followUpQueued = 0,
		followUpQueuedBytes = 0,
	}

	return setmetatable(state, CommandAdmission)
end

return CommandAdmission
