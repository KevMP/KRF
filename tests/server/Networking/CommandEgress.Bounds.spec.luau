--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local Types = require(KRF.server.Networking.types)
local Egress = require(KRF.server.Networking.utils.CommandEgress)
local Timer = require(KRF.shared.Networking.utils.CommandTimer)
local Constants = require(KRF.shared.Networking.utils.CommandConstants)

it("owns a native expiry timer that fires once and allows cancellation from its callback", function()
	local delivered: BindableEvent = Instance.new("BindableEvent")
	local calls: number = 0
	local cancel: () -> () = function(): () end

	cancel = Timer.Schedule(0, function(): ()
		calls += 1
		cancel()
		delivered:Fire()
	end)

	delivered.Event:Wait()
	cancel()
	cancel()
	delivered:Destroy()
	expect(calls).toBe(1)
end)

it("cancels native expiry before delivery and treats repeated cancellation as a no-op", function()
	local delivered: BindableEvent = Instance.new("BindableEvent")
	local calls: number = 0

	local cancel: () -> () = Timer.Schedule(0, function(): ()
		calls += 1
	end)

	cancel()
	cancel()

	task.defer(function(): ()
		delivered:Fire()
	end)

	delivered.Event:Wait()
	delivered:Destroy()
	expect(calls).toBe(0)
end)

for _, observer: boolean in { true, false } do
	it("owns a finite deadline for stalled results with expiry observer " .. tostring(observer), function()
		local original: typeof(Timer.Schedule) = Timer.Schedule
		local fire: (() -> ())? = nil
		local expired: number = 0

		Timer.Schedule = function(seconds: number, callback: () -> ()): () -> ()
			expect(seconds > 0 and seconds < math.huge).toBe(true)
			fire = callback

			return function(): () end
		end

		local completed: boolean, reason: any = pcall(function()
			local state: Egress.State = Egress.new(if observer
				then function(): ()
					expired += 1
				end
				else nil)

			local reserved: Types.CommandReservation? = Egress.Reserve(state, 100)
			assert(reserved ~= nil, "Expected reserved output capacity")
			reserved.Commit(buffer.create(20))
			assert(fire ~= nil, "A committed result must not retain capacity indefinitely")
			fire()
			expect(expired).toBe(if observer then 1 else 0)
			expect(state.reservedBytes).toBe(0)
			expect(state.queue).toEqual({})
			Egress.Destroy(state)
		end)

		Timer.Schedule = original

		if not completed then
			error(reason, 0)
		end
	end)
end

it("reserves count and bytes before execution and releases each charge exactly once", function()
	local state: Egress.State = Egress.new()
	local token: Types.CommandReservation? = Egress.Reserve(state, 100)
	assert(token ~= nil, "Expected reservation")
	expect((Egress.Reserve(state, 100))).toBeNil()
	expect(Egress.AdmitPublication(state, 80)).toBe(true)
	expect(state.fencedBytes).toBe(80)
	expect(token.Commit(buffer.create(20))).toBe(true)
	expect(token.Commit(buffer.create(20))).toBe(false)
	expect(Egress.AdmitPublication(state, Constants.MAX_FENCED_BYTES + 1)).toBe(true)
	local entry: Egress.Entry = state.queue[1]
	Egress.Release(state, entry)
	Egress.Release(state, entry)
	token.Cancel()
	expect(state.reservedBytes).toBe(0)
	expect(state.fencedBytes).toBe(0)
	expect(state.fencedRecords).toBe(0)
	expect(state.scope).toBeNil()
	Egress.Destroy(state)
	expect((Egress.Reserve(state, 1))).toBeNil()
	expect(token.Commit(buffer.create(0))).toBe(false)
end)

it("rejects invalid reservations, exhausted ordering and oversized commits without retaining capacity", function()
	local state: Egress.State = Egress.new()

	for _, bytes: number in { 0, -1, 0.5, Constants.MAX_RESULT_BYTES + 1, math.huge } do
		local token: Types.CommandReservation?, reason: string? = Egress.Reserve(state, bytes)
		expect(token).toBeNil()
		expect(reason).toBe("InvalidCommandReservation")
	end

	local token: Types.CommandReservation? = Egress.Reserve(state, 1)
	assert(token ~= nil, "Expected bounded reservation")
	expect(token.Commit(buffer.create(2))).toBe(false)
	expect(state.queue).toEqual({})
	state.order = Constants.MAX_COUNTER
	local rejected: Types.CommandReservation?, reason: string? = Egress.Reserve(state, 1)
	expect(rejected).toBeNil()
	expect(reason).toBe("CommandOutboundFull")
	Egress.Destroy(state)
end)

for _, bound: string in { "Count", "Bytes" } do
	it("refuses new handlers when undelivered results reach the outbound " .. bound .. " bound", function()
		local state: Egress.State = Egress.new()
		local size: number = if bound == "Count" then 1 else Constants.MAX_RESULT_BYTES

		local count: number = if bound == "Count"
			then Constants.MAX_OUTBOUND_RESULTS
			else math.floor(Constants.MAX_OUTBOUND_BYTES / size)

		for _ = 1, count do
			local token: Types.CommandReservation? = Egress.Reserve(state, size)
			assert(token ~= nil, "Expected exact bounded capacity")
			expect(token.Commit(buffer.create(1))).toBe(true)
		end

		expect((Egress.Reserve(state, size))).toBeNil()
		Egress.Destroy(state)
		expect(state.reservedBytes).toBe(0)
	end)
end

it("bounds fenced records and bytes across outstanding results without charging independent work", function()
	local state: Egress.State = Egress.new()
	local token: Types.CommandReservation? = Egress.Reserve(state, 1)
	assert(token ~= nil, "Expected reservation")
	expect(Egress.AdmitPublication(state, Constants.MAX_FENCED_BYTES)).toBe(true)
	expect(Egress.AdmitPublication(state, 1)).toBe(false)
	token.Cancel()
	token = Egress.Reserve(state, 1)
	assert(token ~= nil, "Canceled scope must release capacity")

	for _ = 1, Constants.MAX_FENCED_RECORDS do
		expect(Egress.AdmitPublication(state, 0)).toBe(true)
	end

	expect(Egress.AdmitPublication(state, 0)).toBe(false)
	Egress.Destroy(state)
	expect(state.fencedRecords).toBe(0)
end)
