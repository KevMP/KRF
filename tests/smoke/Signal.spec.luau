--!strict
-- Smoke tests for shared Signal wrapper + GoodSignal behavior

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)

type ItFn = (name: string, fn: () -> ()) -> ()
local it: ItFn = JestGlobals.it

local expect: any = JestGlobals.expect

local SignalTypes = require(ReplicatedStorage.Packages.KRF.shared.Signal.types)
local GoodSignal: any = require(ReplicatedStorage.Packages.KRF.shared.Signal.GoodSignal)

type Connection = SignalTypes.Connection
type Event<T...> = SignalTypes.Event<T...>
type Signal<T...> = SignalTypes.Signal<T...>
type New = SignalTypes.New
type WrapEvent = SignalTypes.WrapEvent

local SignalModule: { new: New, wrapEvent: WrapEvent } =
	require(ReplicatedStorage.Packages.KRF.shared.Signal.SignalModule)

local function pump(steps: number?): ()
	local n: number = steps or 1
	for _ = 1, n do
		task.wait()
	end
end

local function waitUntil(predicate: () -> boolean, maxSteps: number?): boolean
	local limit: number = maxSteps or 30
	for _ = 1, limit do
		if predicate() then
			return true
		end
		task.wait()
	end
	return predicate()
end

it("new() returns a strict Signal surface (invalid member access throws)", function()
	local sig: Signal<> = SignalModule.new()

	local sigAny: any = sig
	expect(type(sigAny.Connect)).toBe("function")
	expect(type(sigAny.Once)).toBe("function")
	expect(type(sigAny.Wait)).toBe("function")
	expect(type(sigAny.Fire)).toBe("function")
	expect(type(sigAny.DisconnectAll)).toBe("function")
	expect(type(sigAny.Destroy)).toBe("function")

	expect(function()
		local _: any = sigAny.NotARealMember
	end).toThrow()

	expect(function()
		sigAny.NotARealMember = true
	end).toThrow()
end)

it("wrapEvent() returns a strict Event surface (no Fire/DisconnectAll/Destroy)", function()
	local signal: Signal<> = SignalModule.new()
	local event: Event<> = SignalModule.wrapEvent(signal)

	local eventAny: any = event
	expect(type(eventAny.Connect)).toBe("function")
	expect(type(eventAny.Once)).toBe("function")
	expect(type(eventAny.Wait)).toBe("function")

	expect(function()
		local _: any = eventAny.Fire
	end).toThrow()

	expect(function()
		local _: any = eventAny.DisconnectAll
	end).toThrow()

	expect(function()
		local _: any = eventAny.Destroy
	end).toThrow()

	expect(function()
		local _: any = eventAny.NotARealMember
	end).toThrow()

	expect(function()
		eventAny.NotARealMember = true
	end).toThrow()
end)

it("raw GoodSignal surfaces reject invalid member access and assignment", function()
	local rawSignal: any = GoodSignal.new()
	local connection: any = rawSignal:Connect(function() end)
	local connectionClass: any = getmetatable(connection)

	expect(function()
		local _: any = rawSignal.NotARealMember
	end).toThrow()

	expect(function()
		local _: any = GoodSignal.NotARealMember
	end).toThrow()

	expect(function()
		GoodSignal.NotARealMember = true
	end).toThrow()

	expect(function()
		local _: any = connection.NotARealMember
	end).toThrow()

	expect(function()
		local _: any = connectionClass.NotARealMember
	end).toThrow()

	expect(function()
		connectionClass.NotARealMember = true
	end).toThrow()
end)

it("Fire() does not wait for handlers to complete (non-blocking)", function()
	local signal: Signal<> = SignalModule.new()
	local event: Event<> = SignalModule.wrapEvent(signal)

	local called: boolean = false
	local _connection: Connection = event:Connect(function()
		task.wait()
		called = true
	end)

	signal:Fire()

	-- Deterministic: handler cannot reach `called = true` before the wait yields.
	expect(called).toBe(false)

	local ok: boolean = waitUntil(function(): boolean
		return called
	end, 30)

	expect(ok).toBe(true)
end)

it("Connect() returns a Connection with Disconnect(), and Disconnect() prevents future calls", function()
	local signal: Signal<> = SignalModule.new()
	local evemt: Event<> = SignalModule.wrapEvent(signal)

	local count: number = 0
	local connection: Connection = evemt:Connect(function()
		count += 1
	end)

	connection:Disconnect()
	signal:Fire()
	pump(2)

	expect(count).toBe(0)
end)

it("Disconnect() is stable when called again after a non-head connection was already removed", function()
	local signal: Signal<> = SignalModule.new()
	local event: Event<> = SignalModule.wrapEvent(signal)

	local tailCount: number = 0
	local headCount: number = 0

	local tailConnection: Connection = event:Connect(function()
		tailCount += 1
	end)

	local _headConnection: Connection = event:Connect(function()
		headCount += 1
	end)

	tailConnection:Disconnect()
	tailConnection:Disconnect()

	signal:Fire()
	pump(2)

	expect(headCount).toBe(1)
	expect(tailCount).toBe(0)
end)

it("Once() handler runs exactly once across multiple fires", function()
	local signal: Signal<> = SignalModule.new()
	local event: Event<> = SignalModule.wrapEvent(signal)

	local count: number = 0
	local _connection: Connection = event:Once(function()
		count += 1
	end)

	signal:Fire()
	signal:Fire()
	signal:Fire()
	pump(3)

	expect(count).toBe(1)
end)

it("Once() does not run if its connection was disconnected before the first fire", function()
	local signal: Signal<> = SignalModule.new()
	local event: Event<> = SignalModule.wrapEvent(signal)

	local count: number = 0
	local connection: Connection = event:Once(function()
		count += 1
	end)

	connection:Disconnect()
	signal:Fire()
	pump(2)

	expect(count).toBe(0)
end)

it("Multiple Event wrappers over the same Signal all receive fires", function()
	local signal: Signal<> = SignalModule.new()
	local eventA: Event<> = SignalModule.wrapEvent(signal)
	local eventB: Event<> = SignalModule.wrapEvent(signal)

	local a: number = 0
	local b: number = 0

	local _connectionA: Connection = eventA:Connect(function()
		a += 1
	end)

	local _connectionB: Connection = eventB:Connect(function()
		b += 1
	end)

	signal:Fire()
	pump(2)

	expect(a).toBe(1)
	expect(b).toBe(1)
end)

it("DisconnectAll() drops all handlers (no further calls)", function()
	local signal: Signal<> = SignalModule.new()
	local event: Event<> = SignalModule.wrapEvent(signal)

	local count: number = 0
	local _connectionA: Connection = event:Connect(function()
		count += 1
	end)
	local _connectionB: Connection = event:Connect(function()
		count += 1
	end)

	signal:DisconnectAll()
	signal:Fire()
	pump(2)

	expect(count).toBe(0)
end)

it("Wait() resumes with fired arguments (single waiter)", function()
	local signal: Signal<number, string> = SignalModule.new()
	local event: Event<number, string> = SignalModule.wrapEvent(signal)

	local receivedX: number? = nil
	local receivedY: string? = nil

	task.spawn(function()
		local x: number, y: string = event:Wait()
		receivedX = x
		receivedY = y
	end)

	-- ensure waiter is actually waiting
	pump(1)

	signal:Fire(7, "hello")

	local ok: boolean = waitUntil(function(): boolean
		return receivedX ~= nil and receivedY ~= nil
	end, 30)

	expect(ok).toBe(true)
	expect(receivedX).toBe(7)
	expect(receivedY).toBe("hello")
end)

it("Wait() supports multiple simultaneous waiters (all resume on next fire)", function()
	local signal: Signal<string> = SignalModule.new()
	local event: Event<string> = SignalModule.wrapEvent(signal)

	local r1: string? = nil
	local r2: string? = nil

	task.spawn(function()
		local a: string = event:Wait()
		r1 = a
	end)

	task.spawn(function()
		local a: string = event:Wait()
		r2 = a
	end)

	pump(1)
	signal:Fire("go")

	local ok: boolean = waitUntil(function(): boolean
		return r1 ~= nil and r2 ~= nil
	end, 30)

	expect(ok).toBe(true)
	expect(r1).toBe("go")
	expect(r2).toBe("go")
end)

it("Yield-safe: a yielding handler does not prevent other handlers from running", function()
	local signal: Signal<> = SignalModule.new()
	local event: Event<> = SignalModule.wrapEvent(signal)

	local fastRan: boolean = false
	local slowRan: boolean = false

	local _slow: Connection = event:Connect(function()
		task.wait()
		slowRan = true
	end)

	local _fast: Connection = event:Connect(function()
		fastRan = true
	end)

	signal:Fire()

	-- after one tick, the fast handler should have run
	local okFast: boolean = waitUntil(function(): boolean
		return fastRan
	end, 30)
	expect(okFast).toBe(true)

	-- and the slow handler should finish shortly after
	local okSlow: boolean = waitUntil(function(): boolean
		return slowRan
	end, 60)
	expect(okSlow).toBe(true)
end)

it("Disconnect during Fire: a handler can disconnect a later handler before it runs", function()
	local signal: Signal<> = SignalModule.new()
	local event: Event<> = SignalModule.wrapEvent(signal)

	local bRan: boolean = false
	local cnB: Connection = event:Connect(function()
		bRan = true
	end)

	local cnA: Connection = event:Connect(function()
		-- GoodSignal is LIFO: A runs before B because A connected last.
		cnB:Disconnect()
	end)

	-- keep cnA referenced so it isn't GC'd in weird environments
	expect(cnA).never.toBeNil()

	signal:Fire()
	pump(2)

	expect(bRan).toBe(false)
end)

it("Disconnect during Fire can unlink a tail handler after traversing intermediate nodes", function()
	local signal: Signal<> = SignalModule.new()
	local event: Event<> = SignalModule.wrapEvent(signal)

	local tailRan: boolean = false
	local middleRan: boolean = false

	local tailConnection: Connection = event:Connect(function()
		tailRan = true
	end)

	local _middleConnection: Connection = event:Connect(function()
		middleRan = true
	end)

	local _headConnection: Connection = event:Connect(function()
		tailConnection:Disconnect()
	end)

	signal:Fire()
	pump(2)

	expect(middleRan).toBe(true)
	expect(tailRan).toBe(false)
end)

it("raw GoodSignal skips stale disconnected nodes that remain linked in the handler list", function()
	local rawSignal: any = GoodSignal.new()

	local staleRan: boolean = false
	local liveRan: boolean = false

	local staleConnection: any = rawSignal:Connect(function()
		staleRan = true
	end)

	local _liveConnection: any = rawSignal:Connect(function()
		liveRan = true
	end)

	-- Simulate a stale disconnected node that is still reachable from the current list.
	staleConnection._connected = false

	rawSignal:Fire()
	pump(2)

	expect(liveRan).toBe(true)
	expect(staleRan).toBe(false)
end)

it("Connect during Fire: new connections should not run until the next Fire", function()
	local signal: Signal<> = SignalModule.new()
	local event: Event<> = SignalModule.wrapEvent(signal)

	local cRan: boolean = false

	local _cnA: Connection = event:Connect(function()
		-- connect C during firing
		event:Connect(function()
			cRan = true
		end)
	end)

	signal:Fire()
	pump(2)
	expect(cRan).toBe(false)

	signal:Fire()
	local ok: boolean = waitUntil(function(): boolean
		return cRan
	end, 30)
	expect(ok).toBe(true)
end)

it(
	"Once() still delivers an already-fired callback if the returned connection is disconnected before the queued callback runs",
	function()
		local signal: Signal<> = SignalModule.new()
		local event: Event<> = SignalModule.wrapEvent(signal)

		local count: number = 0
		local connection: Connection = event:Once(function()
			count += 1
		end)

		signal:Fire()
		connection:Disconnect()
		pump(2)

		expect(count).toBe(1)
	end
)

it("Destroy() makes Signal inert and disables existing Event surfaces", function()
	local sig: Signal<> = SignalModule.new()
	local ev: Event<> = SignalModule.wrapEvent(sig)

	sig:Destroy()

	expect(function()
		sig:Fire()
	end).toThrow()

	expect(function()
		sig:Connect(function() end)
	end).toThrow()

	expect(function()
		sig:Once(function() end)
	end).toThrow()

	expect(function()
		sig:Wait()
	end).toThrow()

	expect(function()
		sig:DisconnectAll()
	end).toThrow()

	expect(function()
		ev:Connect(function() end)
	end).toThrow()

	expect(function()
		ev:Once(function() end)
	end).toThrow()

	expect(function()
		ev:Wait()
	end).toThrow()
end)

it("wrapEvent() rejects non-Signal values and destroyed signals", function()
	expect(function()
		SignalModule.wrapEvent({} :: any)
	end).toThrow()

	local sig: Signal<> = SignalModule.new()
	sig:Destroy()

	expect(function()
		SignalModule.wrapEvent(sig)
	end).toThrow()
end)

it("Signal methods work directly on the Signal surface without wrapEvent", function()
	local signal: Signal<number> = SignalModule.new()

	local connectCount: number = 0
	local onceCount: number = 0
	local waitedValue: number? = nil

	local _connected: Connection = signal:Connect(function(_value: number)
		connectCount += 1
	end)

	local _onceConnection: Connection = signal:Once(function(_value: number)
		onceCount += 1
	end)

	task.spawn(function()
		local value: number = signal:Wait()
		waitedValue = value
	end)

	pump(1)

	signal:Fire(10)
	signal:Fire(20)

	local ok: boolean = waitUntil(function(): boolean
		return waitedValue ~= nil
	end, 30)

	expect(ok).toBe(true)
	expect(connectCount).toBe(2)
	expect(onceCount).toBe(1)
	expect(waitedValue).toBe(10)
end)

it("Signal and Event methods reject invalid receivers", function()
	local signal: Signal<> = SignalModule.new()
	local event: Event<> = SignalModule.wrapEvent(signal)

	local signalConnect: any = (signal :: any).Connect
	local eventConnect: any = (event :: any).Connect

	expect(function()
		signalConnect({}, function() end)
	end).toThrow()

	expect(function()
		eventConnect({}, function() end)
	end).toThrow()
end)
