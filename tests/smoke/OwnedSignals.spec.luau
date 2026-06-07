--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local it = JestGlobals.it

local expect = JestGlobals.expect

local SignalTypes = require(ReplicatedStorage.Packages.KRF.shared.Signal.types)
local OwnedSignalsModule = require(ReplicatedStorage.Packages.KRF.shared.Signal.OwnedSignals)

type OwnedSignals = SignalTypes.OwnedSignals
type OwnedSignal = OwnedSignalsModule.OwnedSignal

type FakeSignal = {
	name: string,
	destroyCalls: number,
	Destroy: (self: FakeSignal) -> (),
}

local function createFakeSignal(name: string): FakeSignal
	local fakeSignal: FakeSignal = {
		name = name,
		destroyCalls = 0,
		Destroy = function(self: FakeSignal): ()
			self.destroyCalls += 1
		end,
	}

	return fakeSignal
end

it("Destroy() destroys every owned signal exactly once", function()
	local firstSignal: FakeSignal = createFakeSignal("first")
	local secondSignal: FakeSignal = createFakeSignal("second")
	local thirdSignal: FakeSignal = createFakeSignal("third")

	local ownedSignals: OwnedSignals = OwnedSignalsModule.new({
		firstSignal,
		secondSignal,
		thirdSignal,
	} :: { OwnedSignal })

	ownedSignals:Destroy()

	expect(firstSignal.destroyCalls).toBe(1)
	expect(secondSignal.destroyCalls).toBe(1)
	expect(thirdSignal.destroyCalls).toBe(1)
end)

it("Destroy() is idempotent when called more than once", function()
	local firstSignal: FakeSignal = createFakeSignal("first")
	local secondSignal: FakeSignal = createFakeSignal("second")

	local ownedSignals: OwnedSignals = OwnedSignalsModule.new({
		firstSignal,
		secondSignal,
	} :: { OwnedSignal })

	ownedSignals:Destroy()
	ownedSignals:Destroy()
	ownedSignals:Destroy()

	expect(firstSignal.destroyCalls).toBe(1)
	expect(secondSignal.destroyCalls).toBe(1)
end)

it("WithDeferredDestroy defers physical destruction until the callback finishes", function()
	local firstSignal: FakeSignal = createFakeSignal("first")
	local secondSignal: FakeSignal = createFakeSignal("second")

	local ownedSignals: OwnedSignals = OwnedSignalsModule.new({
		firstSignal,
		secondSignal,
	} :: { OwnedSignal })

	local destroyCallsObservedInsideCallback: number = -1

	ownedSignals:WithDeferredDestroy(function()
		ownedSignals:Destroy()
		destroyCallsObservedInsideCallback = firstSignal.destroyCalls + secondSignal.destroyCalls

		expect(firstSignal.destroyCalls).toBe(0)
		expect(secondSignal.destroyCalls).toBe(0)
	end)

	expect(destroyCallsObservedInsideCallback).toBe(0)
	expect(firstSignal.destroyCalls).toBe(1)
	expect(secondSignal.destroyCalls).toBe(1)
end)

it("nested WithDeferredDestroy calls wait for the outermost callback before flushing destroy", function()
	local firstSignal: FakeSignal = createFakeSignal("first")
	local secondSignal: FakeSignal = createFakeSignal("second")

	local ownedSignals: OwnedSignals = OwnedSignalsModule.new({
		firstSignal,
		secondSignal,
	} :: { OwnedSignal })

	ownedSignals:WithDeferredDestroy(function()
		ownedSignals:WithDeferredDestroy(function()
			ownedSignals:Destroy()

			expect(firstSignal.destroyCalls).toBe(0)
			expect(secondSignal.destroyCalls).toBe(0)
		end)

		expect(firstSignal.destroyCalls).toBe(0)
		expect(secondSignal.destroyCalls).toBe(0)
	end)

	expect(firstSignal.destroyCalls).toBe(1)
	expect(secondSignal.destroyCalls).toBe(1)
end)

it("WithDeferredDestroy unwinds depth and flushes pending destroy before rethrowing callback errors", function()
	local firstSignal: FakeSignal = createFakeSignal("first")
	local secondSignal: FakeSignal = createFakeSignal("second")

	local ownedSignals: OwnedSignals = OwnedSignalsModule.new({
		firstSignal,
		secondSignal,
	} :: { OwnedSignal })

	local success: boolean, errorMessage: any = pcall(function()
		ownedSignals:WithDeferredDestroy(function()
			ownedSignals:Destroy()
			error("DeferredDestroyFailure")
		end)
	end)
	local errorIndex: number? = string.find(tostring(errorMessage), "DeferredDestroyFailure", 1, true)

	expect(success).toBe(false)
	expect(errorIndex).never.toBeNil()
	expect(firstSignal.destroyCalls).toBe(1)
	expect(secondSignal.destroyCalls).toBe(1)
end)

it("WithDeferredDestroy errors after signals have already been destroyed", function()
	local fakeSignal: FakeSignal = createFakeSignal("only")

	local ownedSignals: OwnedSignals = OwnedSignalsModule.new({
		fakeSignal,
	} :: { OwnedSignal })

	ownedSignals:Destroy()

	local success: boolean, errorMessage: any = pcall(function()
		ownedSignals:WithDeferredDestroy(function() end)
	end)
	local errorIndex: number? = string.find(
		tostring(errorMessage),
		"OwnedSignals:WithDeferredDestroy called after signals were destroyed",
		1,
		true
	)

	expect(success).toBe(false)
	expect(errorIndex).never.toBeNil()
	expect(fakeSignal.destroyCalls).toBe(1)
end)

it("new() clones the input array so later mutations do not change which signals are destroyed", function()
	local firstSignal: FakeSignal = createFakeSignal("first")
	local secondSignal: FakeSignal = createFakeSignal("second")
	local replacementSignal: FakeSignal = createFakeSignal("replacement")

	local sourceSignals: { OwnedSignal } = {
		firstSignal,
		secondSignal,
	}

	local ownedSignals: OwnedSignals = OwnedSignalsModule.new(sourceSignals)

	table.clear(sourceSignals)
	table.insert(sourceSignals, replacementSignal)

	ownedSignals:Destroy()

	expect(firstSignal.destroyCalls).toBe(1)
	expect(secondSignal.destroyCalls).toBe(1)
	expect(replacementSignal.destroyCalls).toBe(0)
end)
