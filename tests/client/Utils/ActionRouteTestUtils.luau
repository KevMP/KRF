--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local Types = require(KRF.client.Action.types)
local ActorTypes = require(KRF.client.Actor.types)
local InputTypes = require(KRF.client.Input.types)
local Owner = require(KRF.client.Action.ClientActionOwner)
local Actor = require(KRF.client.Actor.ActorView)
local Registry = require(KRF.client.Actor.utils.ActorViewRegistryState)
local SequenceUtils = require(script.Parent.SequenceTestUtils)

export type Fixture = {
	owner: Types.ClientActionOwner,
	options: Types.ClientActionOwnerOptions,
	input: SequenceUtils.Fixture,
	actor: ActorTypes.ActorView,
	other: ActorTypes.ActorView,
	actors: { ActorTypes.ActorViewOwner },
	selections: { Types.ActionRouteSelection },
	transitions: { Types.EffectiveRouteTransition },
	faults: { string },
	ready: boolean,
	onSink: ((Types.ActionRouteSelection, any?) -> ())?,
}

local Utils = {}

function Utils.actor(fixture: Fixture, id: string): ActorTypes.ActorView
	local actor: ActorTypes.ActorViewOwner = assert(Actor.new(id, nil, {}))
	assert(Registry.Install(actor.view))
	table.insert(fixture.actors, actor)

	return actor.view
end

function Utils.new(guard: Types.ActorSwitchGuard?): Fixture
	Registry.Reset()

	local fixture: Fixture = {
		owner = {} :: Types.ClientActionOwner,
		options = {} :: Types.ClientActionOwnerOptions,
		input = SequenceUtils.new(),
		actor = {} :: ActorTypes.ActorView,
		other = {} :: ActorTypes.ActorView,
		actors = {},
		selections = {},
		transitions = {},
		faults = {},
		ready = true,
	}

	fixture.actor = Utils.actor(fixture, "ActorA")
	fixture.other = Utils.actor(fixture, "ActorB")

	fixture.options = {
		Input = fixture.input.input.owner,
		IsReady = function(): boolean
			return fixture.ready
		end,
		ActivationGuard = guard,
		Sink = function(selection: Types.ActionRouteSelection, parameters: any?): ()
			-- Retain framework metadata only. A mock I5 sink copies parameters inline.
			table.insert(fixture.selections, selection)

			if fixture.onSink ~= nil then
				fixture.onSink(selection, parameters)
			end
		end,
		ReportFault = function(reason: string): ()
			table.insert(fixture.faults, reason)
		end,
	}

	fixture.owner = Owner.new(fixture.options)

	fixture.owner.ObserveRoutes(function(change: Types.EffectiveRouteTransition): ()
		table.insert(fixture.transitions, change)
	end)

	return fixture
end

-- For guards whose activation set does not change between prepare and commit.
function Utils.stableRevision(): number
	return 0
end

function Utils.key(id: string?, gesture: InputTypes.GestureKind?): Types.RouteKey
	return { kind = "Input", inputId = id or "X", gesture = gesture or "Pressed" }
end

function Utils.fixed(key: Types.RouteKey?, actionId: string?): Types.ActionRoute
	return { when = key or Utils.key(), target = { kind = "Fixed", actionId = actionId or "Combat.Punch" } }
end

function Utils.dynamic(
	key: Types.RouteKey,
	resolve: (Types.RouteResolveContext) -> Types.ResolvedAction?
): Types.ActionRoute
	return { when = key, target = { kind = "Dynamic", resolve = resolve } }
end

function Utils.set(
	fixture: Fixture,
	routes: { Types.ActionRoute },
	sourceId: string?,
	priority: number?,
	actor: ActorTypes.ActorView?
): ()
	expect({
		fixture.owner.SetProfileSource(
			actor or fixture.actor,
			sourceId or "Base",
			{ priority = priority, routes = routes }
		),
	}).toEqual({ true })
end

function Utils.select(fixture: Fixture, actor: ActorTypes.ActorView?): ()
	expect({ fixture.owner.SetControlledActor(actor or fixture.actor) }).toEqual({ true })
end

function Utils.route(fixture: Fixture, key: Types.RouteKey?, actor: ActorTypes.ActorView?): Types.RouteQuerySnapshot
	local snapshot: Types.RouteQuerySnapshot = assert(
		fixture.owner.GetEffectiveRoute(actor or fixture.actor, key or Utils.key()),
		"Expected available route inspection"
	)

	return snapshot
end

function Utils.actions(fixture: Fixture): { string }
	local actions: { string } = {}

	for _, selection: Types.ActionRouteSelection in fixture.selections do
		table.insert(actions, selection.actionId)
	end

	return actions
end

function Utils.emit(fixture: Fixture, time: number, id: string?, kind: InputTypes.NativeTransition?, value: any?): ()
	SequenceUtils.emit(fixture.input, time, id or "X", kind, value)
end

function Utils.press(fixture: Fixture, time: number, id: string?): ()
	SequenceUtils.press(fixture.input, time, id or "X")
end

function Utils.destroy(fixture: Fixture): ()
	fixture.owner.Destroy()
	SequenceUtils.destroy(fixture.input)
	Registry.Reset()

	for _, actor: ActorTypes.ActorViewOwner in fixture.actors do
		actor:Destroy()
	end
end

return Utils
