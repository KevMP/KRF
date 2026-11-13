--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local ActionTypes = require(ReplicatedStorage.Packages.KRF.client.Action.types)

local Actions: ActionTypes.ClientActionRuntime =
	require(ReplicatedStorage.Packages.KRF.client.Action.ClientActionRuntime)

local Config = require(ReplicatedStorage.FireDemoInputConfig)
local Schemas = require(ReplicatedStorage.FireDemoShared.RequestSchemas)
local Utils = require(script.Parent.Utils.ActionInputTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
	Utils.ready(fixture, Config.Policies, Schemas)
	assert(fixture.input.SetSource("Core", Config.Source))
	assert(fixture.input.SetContextEnabled("FireDemo", true))
	assert(Actions.SetProfileSource(fixture.actor, "Demo", Config.Profile))
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("fires standalone Q once per press without waiting for a combo", function()
	Utils.emit(fixture, "Pressed", "Q")
	expect(Utils.packets(fixture)).toEqual({ { kind = "KRF.Action.Start", requestId = 1, actionId = "Demo.Fireball" } })
	fixture.clock.Advance(0.2)
	Utils.emit(fixture, "Released", "Q")
	expect(#Utils.packets(fixture)).toBe(1)
end)

for _, held: boolean in { false, true } do
	it("requests only Flame Strike for X-Q-Z with Q held through Z=" .. tostring(held), function()
		Utils.tap(fixture, "X")
		fixture.clock.Advance(0.1)
		Utils.emit(fixture, "Pressed", "Q")
		expect(Utils.packets(fixture)).toEqual({})

		if not held then
			Utils.emit(fixture, "Released", "Q")
		end

		fixture.clock.Advance(0.1)
		Utils.tap(fixture, "Z")

		if held then
			Utils.emit(fixture, "Released", "Q")
		end

		fixture.clock.Advance(0.7)

		expect(Utils.packets(fixture)).toEqual({
			{ kind = "KRF.Action.Start", requestId = 1, actionId = "Demo.FlameStrike" },
		})
	end)
end

it("falls back to one Fireball only after the completed X-Q prefix expires", function()
	Utils.tap(fixture, "X")
	fixture.clock.Advance(0.1)
	Utils.tap(fixture, "Q")
	expect(Utils.packets(fixture)).toEqual({})
	fixture.clock.Advance(0.61)
	expect(Utils.packets(fixture)).toEqual({ { kind = "KRF.Action.Start", requestId = 1, actionId = "Demo.Fireball" } })
	fixture.clock.Advance(2)
	expect(#Utils.packets(fixture)).toBe(1)
end)

it("discards a reserved prefix when its gameplay context is disabled", function()
	Utils.tap(fixture, "X")
	fixture.clock.Advance(0.1)
	Utils.tap(fixture, "Q")
	assert(fixture.input.SetContextEnabled("FireDemo", false))
	fixture.clock.Advance(0.7)
	expect(Utils.packets(fixture)).toEqual({})
	assert(fixture.input.SetContextEnabled("FireDemo", true))
	Utils.tap(fixture, "Q")
	expect(Utils.packets(fixture)).toEqual({ { kind = "KRF.Action.Start", requestId = 1, actionId = "Demo.Fireball" } })
end)
