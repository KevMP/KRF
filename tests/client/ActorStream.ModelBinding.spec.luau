--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF

local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ClientNetworkingTypes = require(KRF.client.Networking.types)
local TestUtils = require(script.Parent.Utils.ActorStreamTestUtils)

local fixture: TestUtils.Fixture

beforeEach(function()
	fixture = TestUtils.new()
end)

afterEach(function()
	TestUtils.destroy(fixture)
end)

for _, beforeAwareness: boolean in { true, false } do
	it(
		"binds a Model whose marker arrives " .. (if beforeAwareness then "before awareness" else "after awareness"),
		function()
			local candidate: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA")

			if beforeAwareness then
				TestUtils.add(fixture, candidate)
			end

			local runtime: ClientNetworkingTypes.ActorStreamRuntime = TestUtils.start(fixture)
			TestUtils.establish(fixture)

			if not beforeAwareness then
				local unbound: ClientNetworkingTypes.ActorStreamRecord? = runtime:GetByHandle(1)
				assert(unbound ~= nil, "Expected aware record")
				expect(unbound.model).toBeNil()
				TestUtils.add(fixture, candidate)
			end

			local record: ClientNetworkingTypes.ActorStreamRecord? = runtime:GetByHandle(1)
			assert(record ~= nil, "Expected aware record")
			expect(record.model).toBe(candidate.model)
			expect(runtime:GetByModel(candidate.model)).toBe(record)
			expect(runtime:GetByActorId("ActorA")).toBe(record)
			expect(fixture.bound).toEqual({ { actor = record, model = candidate.model } })
		end
	)
end

it("unbinds only the Model on stream-out and rebinds the same awareness record on stream-in", function()
	local runtime: ClientNetworkingTypes.ActorStreamRuntime = TestUtils.start(fixture)
	TestUtils.establish(fixture, 1, "ActorA", 1, 7)
	local first: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA")
	TestUtils.add(fixture, first)
	local record: ClientNetworkingTypes.ActorStreamRecord? = runtime:GetByHandle(1)
	assert(record ~= nil, "Expected record")
	TestUtils.remove(fixture, first)
	expect(runtime:GetByHandle(1)).toBe(record)
	expect(runtime:GetByActorId("ActorA")).toBe(record)
	expect(runtime:GetByModel(first.model)).toBeNil()
	expect(record.model).toBeNil()
	expect(fixture.unbound).toEqual({ { actor = record, model = first.model } })
	expect(fixture.removed).toEqual({})
	local second: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA")
	TestUtils.add(fixture, second)
	expect(record.model).toBe(second.model)
	expect(runtime:GetByModel(second.model)).toBe(record)
	expect(#fixture.baselines).toBe(1)
	expect(fixture.baselines[1].revision).toBe(7)
	TestUtils.replace(fixture, 1, 2, 9)
	expect(runtime:GetByHandle(1)).toBe(record)
	expect(record.model).toBe(second.model)
end)

it("deduplicates repeated discovery and unbind notifications", function()
	local runtime: ClientNetworkingTypes.ActorStreamRuntime = TestUtils.start(fixture)
	TestUtils.establish(fixture)
	local candidate: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA")
	TestUtils.add(fixture, candidate)
	TestUtils.add(fixture, candidate)
	expect(#fixture.bound).toBe(1)
	TestUtils.remove(fixture, candidate)
	TestUtils.remove(fixture, candidate)
	expect(#fixture.unbound).toBe(1)
	expect(runtime:GetByModel(candidate.model)).toBeNil()
end)

it("reports conflicting Models without creating two reverse bindings or changing domain truth", function()
	local runtime: ClientNetworkingTypes.ActorStreamRuntime = TestUtils.start(fixture)
	TestUtils.establish(fixture)
	local first: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA")
	local duplicate: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA")
	TestUtils.add(fixture, first)
	TestUtils.add(fixture, duplicate)
	local firstRecord: ClientNetworkingTypes.ActorStreamRecord? = runtime:GetByModel(first.model)
	local duplicateRecord: ClientNetworkingTypes.ActorStreamRecord? = runtime:GetByModel(duplicate.model)
	expect(firstRecord == nil or duplicateRecord == nil).toBe(true)
	expect(#fixture.faults > 0).toBe(true)
	expect(#fixture.baselines).toBe(1)
	expect(fixture.baselines[1].domains["Game.Actions"].value).toEqual({ active = false, mode = "Idle" })
end)

it("does not bind one Model to two Actor ids when its markers conflict", function()
	local runtime: ClientNetworkingTypes.ActorStreamRuntime = TestUtils.start(fixture)
	TestUtils.establish(fixture)
	TestUtils.establish(fixture, 2, "ActorB")
	local first: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA")
	local conflicting: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorB", first.model)
	TestUtils.add(fixture, first)
	TestUtils.add(fixture, conflicting)
	local firstRecord: ClientNetworkingTypes.ActorStreamRecord? = runtime:GetByHandle(1)
	local secondRecord: ClientNetworkingTypes.ActorStreamRecord? = runtime:GetByHandle(2)
	assert(firstRecord ~= nil and secondRecord ~= nil, "Expected aware records")
	expect(firstRecord.model ~= first.model or secondRecord.model ~= first.model).toBe(true)
	expect(#fixture.faults > 0).toBe(true)
end)

it("removes awareness and Model binding even when stale marker presence outlives ActorRemove", function()
	local runtime: ClientNetworkingTypes.ActorStreamRuntime = TestUtils.start(fixture)
	TestUtils.establish(fixture)
	local candidate: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA")
	TestUtils.add(fixture, candidate)
	expect(TestUtils.send(fixture, { { kind = "ActorRemove", handle = 1 } })).toBe(true)
	TestUtils.add(fixture, candidate)
	expect(runtime:GetByHandle(1)).toBeNil()
	expect(runtime:GetByActorId("ActorA")).toBeNil()
	expect(runtime:GetByModel(candidate.model)).toBeNil()
	expect(#fixture.removed).toBe(1)
	expect(#fixture.unbound).toBe(1)
	expect(#fixture.bound).toBe(1)
end)

it("discovers initial markers once and uses added/removed events for later binding", function()
	local runtime: ClientNetworkingTypes.ActorStreamRuntime = TestUtils.start(fixture)
	expect(fixture.scans).toBe(1)
	TestUtils.establish(fixture)

	for _ = 1, 20 do
		local candidate: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA")
		TestUtils.add(fixture, candidate)
		TestUtils.remove(fixture, candidate)
	end

	expect(fixture.scans).toBe(1)
	runtime:Destroy()
	runtime:Destroy()
	fixture.runtime = nil
	expect(fixture.added).toEqual({})
	expect(fixture.gone).toEqual({})
	expect(runtime:GetByHandle(1)).toBeNil()
end)

it("rebinds duplicate candidates within one Actor identity among unrelated streamed Models", function()
	for index: number = 1, 100 do
		TestUtils.add(fixture, TestUtils.candidate(fixture, "Unrelated" .. tostring(index)))
	end

	local first: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA")
	local second: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA")
	TestUtils.add(fixture, first)
	TestUtils.add(fixture, second)
	local runtime: ClientNetworkingTypes.ActorStreamRuntime = TestUtils.start(fixture)
	TestUtils.establish(fixture)
	local record: ClientNetworkingTypes.ActorStreamRecord? = runtime:GetByActorId("ActorA")
	assert(record ~= nil, "Expected aware Actor")
	local bound: ClientNetworkingTypes.ActorModelCandidate = if record.model == first.model then first else second
	local remaining: ClientNetworkingTypes.ActorModelCandidate = if bound == first then second else first
	expect(record.model).toBe(bound.model)
	TestUtils.remove(fixture, bound)
	expect(record.model).toBe(remaining.model)
	expect(runtime:GetByModel(bound.model)).toBeNil()
	expect(runtime:GetByModel(remaining.model)).toBe(record)
	expect(#fixture.unbound).toBe(1)
	expect(#fixture.bound).toBe(2)
	TestUtils.remove(fixture, remaining)
	expect(record.model).toBeNil()
	expect(#fixture.unbound).toBe(2)
	TestUtils.add(fixture, first)
	expect(record.model).toBe(first.model)
	expect(#fixture.bound).toBe(3)
	expect(runtime:GetByHandle(1)).toBe(record)
	expect(#fixture.baselines).toBe(1)
	expect(fixture.scans).toBe(1)
end)

it("moves a reused marker between Actor identities and preserves duplicate markers on the same Model", function()
	local runtime: ClientNetworkingTypes.ActorStreamRuntime = TestUtils.start(fixture)
	TestUtils.establish(fixture)
	TestUtils.establish(fixture, 2, "ActorB")
	local first: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA")
	local duplicate: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA", first.model)
	local alternative: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA")
	TestUtils.add(fixture, first)
	TestUtils.add(fixture, duplicate)
	TestUtils.add(fixture, alternative)
	local firstRecord: ClientNetworkingTypes.ActorStreamRecord? = runtime:GetByActorId("ActorA")
	local secondRecord: ClientNetworkingTypes.ActorStreamRecord? = runtime:GetByActorId("ActorB")
	assert(firstRecord ~= nil and secondRecord ~= nil, "Expected aware Actors")
	TestUtils.remove(fixture, first)
	expect(firstRecord.model).toBe(first.model)
	expect(runtime:GetByModel(first.model)).toBe(firstRecord)
	expect(runtime:GetByModel(alternative.model)).toBeNil()
	expect(#fixture.bound).toBe(1)
	expect(fixture.unbound).toEqual({})
	TestUtils.remove(fixture, first)
	expect(firstRecord.model).toBe(first.model)
	TestUtils.remove(fixture, alternative)
	expect(firstRecord.model).toBe(first.model)
	expect(#fixture.bound).toBe(1)
	expect(fixture.unbound).toEqual({})
	TestUtils.remove(fixture, duplicate)
	expect(firstRecord.model).toBeNil()
	expect(#fixture.unbound).toBe(1)

	local reassigned: ClientNetworkingTypes.ActorModelCandidate =
		{ marker = first.marker, model = first.model, actorId = "ActorB" }

	TestUtils.add(fixture, reassigned)
	expect(firstRecord.model).toBeNil()
	expect(secondRecord.model).toBe(first.model)
	expect(runtime:GetByModel(first.model)).toBe(secondRecord)
	expect(#fixture.bound).toBe(2)
	TestUtils.remove(fixture, reassigned)
	expect(secondRecord.model).toBeNil()
	expect(#fixture.unbound).toBe(2)
	local fresh: ClientNetworkingTypes.ActorModelCandidate = TestUtils.candidate(fixture, "ActorA")
	TestUtils.add(fixture, fresh)
	expect(firstRecord.model).toBe(fresh.model)
	expect(#fixture.bound).toBe(3)
	expect(secondRecord.model).toBeNil()
	expect(fixture.faults).toEqual({ "ActorModelConflict" })
end)
