--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local expect: any = JestGlobals.expect
local Types = require(KRF.client.Actor.types)
local SharedTypes = require(KRF.shared.Networking.types)
local SignalTypes = require(KRF.shared.Signal.types)
local Schema: SharedTypes.Schema = require(KRF.shared.Networking.Schema)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local ActorUtils = require(script.Parent.ActorViewTestUtils)

-- Test-side contracts keep absent N8 APIs as assertions, not load/type failures.
export type Snapshot = { read actionId: string, read sequenceId: number }

export type ActionsView = {
	read IsActionActive: (self: ActionsView, actionId: string) -> boolean,
	read GetAction: (self: ActionsView, sequenceId: number) -> Snapshot?,
	read GetActiveActions: (self: ActionsView) -> { Snapshot },
	read OnActionStarted: SignalTypes.Event<Snapshot>,
	read OnActionEnded: SignalTypes.Event<Snapshot>,
	read OnActionInterrupted: SignalTypes.Event<Snapshot>,
	read OnStateChanged: SignalTypes.Event<Types.DomainChangeSource>,
}

local TestUtils = {}

function TestUtils.get(actor: Types.ActorView): ActionsView
	local candidate: any = actor
	expect(type(candidate.GetActions)).toBe("function")

	return candidate:GetActions() :: ActionsView
end

function TestUtils.manifest(): SharedTypes.ProtocolManifest
	local ids: SharedTypes.SchemaDefinition = Schema.Enum({ "Action.A", "Action.B" })
	local identity: SharedTypes.SchemaDefinition = Schema.Struct({ actionId = ids, sequenceId = Schema.U32 })

	return {
		version = Constants.PROTOCOL_VERSION,
		domains = {
			{
				id = "KRF.Actions",
				code = 0,
				state = Schema.Map(Schema.U32, ids, 256),
				events = {
					{ id = "Ended", code = 0, payload = identity },
					{ id = "Interrupted", code = 1, payload = identity },
					{ id = "Started", code = 2, payload = identity },
				},
			},
		},
	}
end

function TestUtils.new(): ActorUtils.Fixture
	return ActorUtils.new(nil, TestUtils.manifest())
end

function TestUtils.truth(state: { [number]: string }): { [string]: SharedTypes.ActorDomainTruth }
	return { ["KRF.Actions"] = { value = state } }
end

function TestUtils.baseline(fixture: ActorUtils.Fixture, state: { [number]: string }): Types.ActorView
	ActorUtils.baseline(fixture, nil, nil, nil, TestUtils.truth(state))

	return ActorUtils.view(fixture)
end

function TestUtils.patch(entries: { [number]: string }, removed: { number }): SharedTypes.ActorDomainPatch
	return { domainId = "KRF.Actions", patch = { kind = "Map", entries = entries, removed = removed } }
end

function TestUtils.event(kind: string, id: string, sequence: number): SharedTypes.ActorEvent
	return { domainId = "KRF.Actions", eventId = kind, payload = { actionId = id, sequenceId = sequence } }
end

return TestUtils
