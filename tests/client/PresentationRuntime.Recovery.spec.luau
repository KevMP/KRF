--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local afterEach: any = JestGlobals.afterEach
local PublicTypes = require(KRF.client.Actor.types)
local ClientNetworkingTypes = require(KRF.client.Networking.types)
local SharedNetworkingTypes = require(KRF.shared.Networking.types)
local Schema: SharedNetworkingTypes.Schema = require(KRF.shared.Networking.Schema)
local Constants = require(KRF.shared.Networking.utils.ProtocolConstants)
local Types = require(KRF.client.Presentation.types)
local Events = require(KRF.client.Presentation.PresentationEvents)
local States = require(KRF.client.Presentation.PresentationStates)
local Registry = require(KRF.client.Presentation.PresentationRegistry)
local Runtime = require(KRF.client.Presentation.PresentationRuntime)
local Hints = require(KRF.client.Networking.utils.HintRuntimeState)
local TestUtils = require(script.Parent.Utils.ActorViewTestUtils)

local fixture: TestUtils.Fixture? = nil
local shutdown: (() -> ())? = nil

afterEach(function()
	if shutdown ~= nil then
		shutdown()
		shutdown = nil
	end

	if fixture ~= nil then
		TestUtils.destroy(fixture)
		fixture = nil
	end
end)

local tagId: SharedNetworkingTypes.SchemaDefinition = Schema.String(32)

local manifest: SharedNetworkingTypes.ProtocolManifest = {
	version = Constants.PROTOCOL_VERSION,
	domains = {
		{
			id = "KRF.Tags",
			code = 0,
			state = Schema.Map(
				tagId,
				Schema.Struct({ stackCount = Schema.U32, expiresAt = Schema.Optional(Schema.F64) }),
				8
			),
			events = {
				{ id = "Added", code = 0, payload = tagId },
				{ id = "Refreshed", code = 1, payload = tagId },
				{ id = "Removed", code = 2, payload = tagId },
				{ id = "Expired", code = 3, payload = tagId },
			},
		},
	},
}

local function tags(state: { [string]: number }): { [string]: SharedNetworkingTypes.ActorDomainTruth }
	local value: { [string]: { stackCount: number } } = {}

	for id: string, stacks: number in state do
		value[id] = { stackCount = stacks }
	end

	return { ["KRF.Tags"] = { value = value } }
end

it("preserves state instances through real recovery, defers stale Watches and reconciles the replacement", function()
	local current: TestUtils.Fixture = TestUtils.new(nil, manifest)
	fixture = current

	local readiness: ClientNetworkingTypes.ActorViewStateReadinessSource = table.freeze({
		IsStateReady = function(
			_self: ClientNetworkingTypes.ActorViewStateReadinessSource,
			actor: PublicTypes.ActorView
		): boolean
			return current.runtime:IsStateReady(actor)
		end,
		ObserveStateReadiness = function(
			_self: ClientNetworkingTypes.ActorViewStateReadinessSource,
			callback: ClientNetworkingTypes.ActorViewStateReadinessObserver
		): () -> ()
			return current.runtime:ObserveStateReadiness(callback)
		end,
	})

	local auras: { [string]: { Types.PresentationContext } } = { Burning = {}, Frozen = {}, Shocked = {} }
	local earlier: { number } = {}
	local later: { number } = {}
	local definitions: { Types.PresentationDefinition } = {}

	for id: string in auras do
		table.insert(definitions, {
			id = id .. ".Aura",
			entry = { state = States.Tag.Active, id = id },
			create = function(context: Types.PresentationContext)
				table.insert(auras[id], context)

				if id == "Burning" then
					context:Watch(States.Tag.Active, "Burning", function(tag: PublicTypes.ActiveTagSnapshot?)
						table.insert(earlier, if tag ~= nil then tag.stackCount else 0)
					end)
				end
			end,
		})
	end

	table.insert(definitions, {
		id = "GapWatcher",
		entry = { event = Events.Hint.Received, id = "Gap" },
		create = function(context: Types.PresentationContext)
			context:Watch(States.Tag.Active, "Burning", function(tag: PublicTypes.ActiveTagSnapshot?)
				table.insert(later, if tag ~= nil then tag.stackCount else 0)
			end)
		end,
	})

	shutdown = assert(Runtime.Install(assert(Registry.Prepare(definitions)), readiness))
	TestUtils.baseline(current, 1, "ActorA", 10, tags({ Burning = 1, Frozen = 1 }))
	local view: PublicTypes.ActorView = TestUtils.view(current)
	task.wait()
	expect(#auras.Burning).toBe(1)
	expect(#auras.Frozen).toBe(1)
	expect(earlier).toEqual({ 1 })
	TestUtils.commit(current, 13)
	expect(view:IsAvailable()).toBe(true)
	expect(current.runtime:IsStateReady(view)).toBe(false)
	Hints.Notify({ hintId = "Gap", actorView = view })
	task.wait()
	expect(later).toEqual({})
	expect(auras.Burning[1]:IsActive()).toBe(true)
	expect(auras.Frozen[1]:IsActive()).toBe(true)
	TestUtils.baseline(current, 1, nil, 20, tags({ Burning = 2, Shocked = 1 }), 2)
	expect(TestUtils.view(current)).toBe(view)
	task.wait()
	expect(#auras.Burning).toBe(1)
	expect(auras.Burning[1]:IsActive()).toBe(true)
	expect(auras.Frozen[1]:IsActive()).toBe(false)
	expect(#auras.Shocked).toBe(1)
	expect(earlier).toEqual({ 1, 2 })
	expect(later).toEqual({ 2 })
end)
