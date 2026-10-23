--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.server.Networking.types)
local SharedTypes = require(KRF.shared.Networking.types)
local ActorTypes = require(KRF.server.Actor.types)
local Constants = require(KRF.shared.Networking.utils.CommandConstants)
local ActorConstants = require(KRF.shared.Networking.utils.ActorProtocolConstants)
local TestUtils = require(script.Parent.Parent.Utils.Networking.CommandRuntimeTestUtils)
local AwarenessUtils = require(script.Parent.Parent.Utils.Networking.AwarenessTestUtils)
local fixture: TestUtils.Fixture? = nil

afterEach(function()
	TestUtils.destroy(fixture)
	fixture = nil
end)

local function publish(current: TestUtils.Fixture, actor: ActorTypes.Actor, value: number): ()
	current.base.publicDomain.value = value
	current.base.publicDomain.callbacks[actor]({ { id = "Changed", payload = value } })
end

local function timeline(current: TestUtils.Fixture, player: Player): { string }
	AwarenessUtils.drain(current.base)
	local observed: { string } = {}

	for _, delivery: AwarenessUtils.Delivery in current.base.deliveries do
		if delivery.player ~= player then
			continue
		end

		if buffer.readu8(delivery.payload, 0) == Constants.RESULT_KIND then
			local result: SharedTypes.CommandResult? = current.codec.DecodeResult(delivery.payload)
			assert(result ~= nil, "Expected actual N9 result codec")
			table.insert(observed, "Result:" .. result.requestId)
		else
			expect(buffer.readu8(delivery.payload, 0)).toBe(ActorConstants.PACKET_KIND)
			local records: { SharedTypes.ActorStreamRecord }? = current.base.codec.Decode(delivery.payload)
			assert(records ~= nil, "Expected actual N4 publication codec")

			for _, record: SharedTypes.ActorStreamRecord in records do
				if record.kind == "Commit" then
					for _, event: SharedTypes.ActorEvent in record.events do
						table.insert(observed, "Changed:" .. tostring(event.payload))
					end
				else
					table.insert(observed, record.kind)
				end
			end
		end
	end

	return observed
end

it(
	"preserves older queued events, then the result, then synchronous cross-Actor effects without fencing observers",
	function()
		local otherActor: ActorTypes.Actor? = nil

		local created: TestUtils.Fixture = TestUtils.new({
			{
				id = "Game.Command",
				target = "None",
				authorize = function(): (boolean, string?)
					return true, nil
				end,
				handle = function(): Types.CommandHandlerResult
					local current: TestUtils.Fixture = fixture :: TestUtils.Fixture
					publish(current, current.actor, 12)
					publish(current, otherActor :: ActorTypes.Actor, 13)
					-- Reentrant publication pumping may release observers, never the requester effects.
					current.awareness:Step(10000, 100)

					return { accepted = true }
				end,
			},
		})

		fixture = created
		otherActor = AwarenessUtils.actor(created.base)
		AwarenessUtils.drain(created.base)
		created.base.deliveries = {}
		publish(created, created.actor, 11)
		TestUtils.send(created, 1)
		local observed: { string } = timeline(created, created.player)
		expect(observed).toEqual({ "Changed:11", "Result:1", "Changed:12", "Changed:13" })
		local observer: { string } = timeline(created, created.other)

		expect((table.find(observer, "Changed:11") :: number) < (table.find(observer, "Changed:12") :: number)).toBe(
			true
		)

		table.sort(observer)
		expect(observer).toEqual({ "Changed:11", "Changed:12", "Changed:13" })
	end
)

it("finishes older queued baselines before results and places command-created identities after the result", function()
	local created: TestUtils.Fixture = TestUtils.new({
		{
			id = "Game.Command",
			target = "None",
			authorize = function(): (boolean, string?)
				return true, nil
			end,
			handle = function(): Types.CommandHandlerResult
				AwarenessUtils.actor((fixture :: TestUtils.Fixture).base)

				return { accepted = true }
			end,
		},
	})

	fixture = created
	AwarenessUtils.actor(created.base)
	TestUtils.send(created, 1)
	local observed: { string } = timeline(created, created.player)
	local resultIndex: number? = table.find(observed, "Result:1")
	assert(resultIndex ~= nil, "Expected result after preexisting baseline")
	expect(observed[1]).toBe("BaselineBegin")
	expect(observed[resultIndex - 1]).toBe("BaselineEnd")
	expect(observed[resultIndex + 1]).toBe("BaselineBegin")
	expect(observed[#observed]).toBe("BaselineEnd")
end)

it("separates successive command boundaries even when state-only publications could coalesce", function()
	local created: TestUtils.Fixture = TestUtils.new({
		{
			id = "Game.Command",
			target = "None",
			authorize = function(): (boolean, string?)
				return true, nil
			end,
			handle = function(context: Types.CommandContext): Types.CommandHandlerResult
				local current: TestUtils.Fixture = fixture :: TestUtils.Fixture
				publish(current, current.actor, 10 + context.requestId)

				return { accepted = true }
			end,
		},
	})

	fixture = created
	TestUtils.send(created, 1)
	TestUtils.send(created, 2)
	expect(timeline(created, created.player)).toEqual({ "Result:1", "Changed:11", "Result:2", "Changed:12" })
end)

it("releases faulted handler effects after Unknown and does not fence later independent publication", function()
	local created: TestUtils.Fixture = TestUtils.new({
		{
			id = "Game.Command",
			target = "None",
			authorize = function(): (boolean, string?)
				return true, nil
			end,
			handle = function(): Types.CommandHandlerResult
				local current: TestUtils.Fixture = fixture :: TestUtils.Fixture
				publish(current, current.actor, 11)
				error("CommittedThenFaulted")
			end,
		},
	})

	fixture = created
	TestUtils.send(created, 1)
	publish(created, created.actor, 12)
	expect(timeline(created, created.player)).toEqual({ "Result:1", "Changed:11", "Changed:12" })
	expect(TestUtils.results(created)[1].status).toBe("Unknown")
end)
