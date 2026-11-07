--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local beforeEach: any = JestGlobals.beforeEach
local afterEach: any = JestGlobals.afterEach
local Types = require(KRF.client.Action.types)
local InputTypes = require(KRF.client.Input.types)
local Runtime: Types.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local State = require(KRF.client.Action.utils.ClientActionRuntimeState)
local InputState = require(KRF.client.Input.utils.InputRuntimeState)
local Installation = require(KRF.client.Action.utils.ClientActionInstallation)
local SequenceUtils = require(script.Parent.Utils.SequenceTestUtils)
local Utils = require(script.Parent.Utils.ActionRouteTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
end)

afterEach(function()
	local installed: Types.ClientActionOwner? = State.Get()

	if installed ~= nil then
		installed.Destroy()
	end

	State.Install(nil)
	InputState.Install(nil)
	Utils.destroy(fixture)
end)

it("routes through the installed frozen facade and contains resolver faults without retaining a prior owner", function()
	InputState.Install(fixture.input.input.owner)

	local stop = Installation.Install(function(): boolean
		return fixture.ready
	end)

	expect({ Runtime.SetProfileSource(fixture.actor, "Base", { routes = { Utils.fixed() } }) }).toEqual({ true })
	expect({ Runtime.SetControlledActor(fixture.actor) }).toEqual({ true })
	expect(Runtime.GetEffectiveRoute(fixture.actor, Utils.key())).toMatchObject({ actionId = "Combat.Punch" })
	expect(Runtime.GetProfileSources(fixture.actor)).toEqual({ { sourceId = "Base", priority = 0, routeCount = 1 } })
	Utils.press(fixture, 0)
	expect({ Runtime.RemoveProfileSource(fixture.actor, "Base") }).toEqual({ true })

	for _, fail: boolean in { false, true } do
		expect({
			Runtime.SetProfileSource(fixture.actor, "Base", {
				routes = {
					Utils.dynamic(Utils.key(), function(): Types.ResolvedAction?
						if fail then
							error("Expected resolver fault", 0)
						end

						return nil
					end),
				},
			}),
		}).toEqual({ true })

		Utils.press(fixture, if fail then 2 else 1)
	end

	local old: Types.ClientActionOwner = assert(State.Get(), "Expected installed owner")

	local stopNew = Installation.Install(function(): boolean
		return fixture.ready
	end)

	local current: Types.ClientActionOwner = assert(State.Get(), "Expected replacement owner")
	expect(current).never.toBe(old)
	stop()
	stop()
	expect(State.Get()).toBe(current)
	current.Destroy()
	expect(State.Get()).toBeNil()
	stopNew()
	stopNew()
end)

it(
	"reports all lost recognition routes and uninstalls an installed action owner on an input publication failure",
	function()
		expect({
			fixture.input.input.owner.SetSource("Recognition", {
				sequences = { Combo = SequenceUtils.pattern({ "X" }) },
				recognizers = {
					Motion = SequenceUtils.recognizer(function(): InputTypes.CustomMatch?
						return nil
					end),
				},
			}),
		}).toEqual({ true })

		InputState.Install(fixture.input.input.owner)

		local stop = Installation.Install(function(): boolean
			return fixture.ready
		end)

		expect({
			Runtime.SetProfileSource(fixture.actor, "Base", {
				routes = {
					Utils.fixed({ kind = "Sequence", sequenceId = "Combo" }),
					Utils.fixed({ kind = "Custom", recognizerId = "Motion" }),
				},
			}),
		}).toEqual({ true })

		local owner: Types.ClientActionOwner = assert(State.Get(), "Expected installed action owner")
		local retired: { Types.EffectiveRouteTransition } = {}

		owner.ObserveRoutes(function(change: Types.EffectiveRouteTransition): ()
			table.insert(retired, change)
		end)

		local plan: InputTypes.PreparedInputUpdate = assert(fixture.input.input.owner.PrepareSource("Empty", {}))

		expect({
			fixture.input.input.owner.CommitPreparedWithPublication(plan, function(): ()
				coroutine.yield()
			end),
		}).toEqual({ false, "InputRuntimeFaulted" })

		expect(#retired).toBe(2)

		for _, change: Types.EffectiveRouteTransition in retired do
			expect(change.previous.status).toBe("Mapped")
			expect(change.next.status).toBe("Unmapped")
		end

		expect(State.Get()).toBeNil()
		expect(Runtime.GetControlledActor()).toBeNil()
		stop()
	end
)
