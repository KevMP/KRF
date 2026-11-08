--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local NetworkingTypes = require(KRF.client.Networking.types)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local CommandState = require(KRF.client.Networking.utils.CommandRuntimeState)
local Utils = require(script.Parent.Utils.ActionInputTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	Utils.destroy(fixture)
end)

local function toggled(policies: Types.ActionInputPolicies?): number
	Utils.ready(fixture, policies or Utils.policies())
	Utils.set(fixture, { Utils.route("Mode.Aura") })
	Utils.tap(fixture)

	return Utils.started(fixture, "Mode.Aura")
end

it("ignores key release and sends original Stop on the second matching trigger without running Start again", function()
	local starts: number = 0
	local stops: number = 0

	local policies: Types.ActionInputPolicies = Utils.policies()

	policies["Mode.Aura"].startParameters = function(): any
		starts += 1

		return nil
	end

	policies["Mode.Aura"].stopParameters = function(): any
		stops += 1

		return nil
	end

	local original: number = toggled(policies)
	expect(#Utils.packets(fixture)).toBe(1)
	Utils.tap(fixture)
	expect({ starts, stops }).toEqual({ 1, 1 })

	expect(Utils.packets(fixture)[2]).toEqual({
		kind = "KRF.Action.Stop",
		requestId = 2,
		originalStartRequestId = original,
		actionId = "Mode.Aura",
	})

	expect(#Utils.packets(fixture)).toBe(2)
end)

it("retires toggle matching on local Stop admission even when server Stop is nonterminal", function()
	local original: number = toggled()
	Utils.outcome(fixture, original, "KRF.Action.Start", "Accepted")
	Utils.tap(fixture)
	Utils.outcome(fixture, 2, "KRF.Action.Stop", "Accepted")
	Utils.tap(fixture)
	expect(Utils.packets(fixture)[3]).toMatchObject({ kind = "KRF.Action.Start", actionId = "Mode.Aura" })
	expect(#Utils.packets(fixture)).toBe(3)
end)

it("matches original canonical route and concrete Action when equipment changes on the same dynamic slot", function()
	Utils.ready(fixture, Utils.policies())
	local equipped: string = "Mode.Aura"
	local resolverCalls: number = 0

	Utils.set(fixture, {
		{
			when = Utils.key(),
			target = {
				kind = "Dynamic",
				resolve = function(): Types.ResolvedAction
					resolverCalls += 1

					return { actionId = equipped }
				end,
			},
		},
	})

	Utils.tap(fixture)
	local original: number = Utils.started(fixture, "Mode.Aura")
	equipped = "Combat.Fireball"
	Utils.tap(fixture)
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Start", actionId = "Combat.Fireball" })
	equipped = "Mode.Aura"
	Utils.tap(fixture)

	expect(Utils.packets(fixture)[3]).toMatchObject({
		kind = "KRF.Action.Stop",
		originalStartRequestId = original,
		actionId = "Mode.Aura",
	})

	expect(resolverCalls).toBe(3)
end)

it("keeps independent toggle records for the same Action on different semantic routes", function()
	Utils.ready(fixture, Utils.policies())
	Utils.set(fixture, { Utils.route("Mode.Aura"), Utils.route("Mode.Aura", Utils.key("Other")) })
	Utils.tap(fixture)
	Utils.started(fixture, "Mode.Aura")
	Utils.tap(fixture, "Other")
	Utils.tap(fixture)
	Utils.tap(fixture, "Other")
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Start", actionId = "Mode.Aura" })
	expect(Utils.packets(fixture)[3]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = 1 })
	expect(Utils.packets(fixture)[4]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = 2 })
end)

it("preserves toggle matching across equivalent profile reapplication", function()
	local original: number = toggled()
	Utils.set(fixture, { Utils.route("Mode.Aura") })
	Utils.tap(fixture)
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = original })
end)

it("detaches default Keep on route removal and starts fresh after the same route is reinstalled", function()
	toggled()
	expect({ Runtime.RemoveProfileSource(fixture.actor, "Base") }).toEqual({ true })
	expect(#Utils.packets(fixture)).toBe(1)
	Utils.set(fixture, { Utils.route("Mode.Aura") })
	Utils.tap(fixture)
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Start", actionId = "Mode.Aura" })
	Utils.tap(fixture)
	expect(Utils.packets(fixture)[3]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = 2 })
end)

it("never reattaches a kept toggle after A to B to A Actor switches", function()
	toggled()
	Utils.set(fixture, { Utils.route("Mode.Aura") }, fixture.other)
	expect({ Runtime.SetControlledActor(fixture.other) }).toEqual({ true })
	Utils.tap(fixture)
	expect({ Runtime.SetControlledActor(fixture.actor) }).toEqual({ true })
	Utils.tap(fixture)
	local packets: { Utils.Packet } = Utils.packets(fixture)
	expect(#packets).toBe(3)

	for _, packet: Utils.Packet in packets do
		expect(packet.kind).toBe("KRF.Action.Start")
	end
end)

it("uses explicit Toggle Interrupt invalidation without running its Stop producer", function()
	local calls: number = 0

	local policies: Types.ActionInputPolicies = Utils.policies()
	policies["Mode.Aura"].onInvalidation = "Interrupt"

	policies["Mode.Aura"].stopParameters = function(): any
		calls += 1

		return nil
	end

	local original: number = toggled(policies)
	expect({ Runtime.RemoveProfileSource(fixture.actor, "Base") }).toEqual({ true })
	expect(calls).toBe(0)
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Interrupt", originalStartRequestId = original })
end)

it("treats Unknown and absent replicated liveness as uncertainty and targets the old receipt on toggle-off", function()
	local original: number = toggled()
	fixture.clock.Advance(35)
	Utils.tap(fixture)
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = original })
	expect(#Utils.packets(fixture)).toBe(2)
end)

it("retires a rejected toggle Start so the next trigger can attempt a fresh Start", function()
	local original: number = toggled()
	Utils.outcome(fixture, original, "KRF.Action.Start", "Rejected", "ActionNotGranted")
	Utils.tap(fixture)
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Start", actionId = "Mode.Aura" })
end)

it("coalesces a not-admitted toggle-off without resampling its producer or sending a fresh Start", function()
	local calls: number = 0

	local policies: Types.ActionInputPolicies = Utils.policies()

	policies["Mode.Aura"].stopParameters = function(): any
		calls += 1

		return nil
	end

	local original: number = toggled(policies)
	local commands: NetworkingTypes.ClientCommandRuntime = assert(CommandState.Get())
	local send = commands._SendAdmitted
	local pressure: boolean = true
	local attempts: { string } = {}

	commands._SendAdmitted = function(
		self: NetworkingTypes.ClientCommandRuntime,
		commandId: string,
		actor: ActorTypes.ActorView?,
		parameters: any?,
		admit: NetworkingTypes.CommandAdmission,
		committed: ((number) -> ())?
	): (number?, string?)
		table.insert(attempts, commandId)

		if commandId == "KRF.Action.Stop" and pressure then
			return nil, "CommandPendingFull"
		end

		return send(self, commandId, actor, parameters, admit, committed)
	end

	Utils.tap(fixture)
	Utils.tap(fixture)
	expect(calls).toBe(1)
	expect(#Utils.packets(fixture)).toBe(1)
	expect(attempts).never.toContain("KRF.Action.Start")
	expect(attempts).never.toContain("KRF.Action.Interrupt")
	pressure = false
	Utils.outcome(fixture, original, "KRF.Action.Start", "Accepted")
	fixture.clock.Advance(0.01)
	expect(Utils.packets(fixture)[2]).toMatchObject({ kind = "KRF.Action.Stop", originalStartRequestId = original })
	expect(calls).toBe(1)
end)
