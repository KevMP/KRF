--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: (string, () -> ()) -> () = (JestGlobals.it :: unknown) :: (string, () -> ()) -> ()
local expect = JestGlobals.expect
local beforeEach: (() -> ()) -> () = (JestGlobals.beforeEach :: unknown) :: (() -> ()) -> ()
local afterEach: (() -> ()) -> () = (JestGlobals.afterEach :: unknown) :: (() -> ()) -> ()
local Types = require(KRF.client.Controls.types)
local Controls: Types.ClientControls = require(KRF.client.Controls.ClientControls)
local ActionTypes = require(KRF.client.Action.types)
local Runtime: ActionTypes.ClientActionRuntime = require(KRF.client.Action.ClientActionRuntime)
local ActionUtils = require(script.Parent.Utils.ActionInputTestUtils)
local Utils = require(script.Parent.Utils.ControlTestUtils)
local fixture: Utils.Fixture

beforeEach(function()
	fixture = Utils.new()
	Utils.ready(fixture)
end)

afterEach(function()
	Utils.destroy(fixture)
end)

it("keeps selection for omitted and empty arrays and supports explicit tagged nil selection", function()
	for _, changes: Types.ControlChangeSet in { {}, { inputs = {}, profiles = {}, contexts = {} } } do
		local graph = fixture.base.input.GetGraphSnapshot()
		Utils.apply(changes)
		expect(Runtime.GetControlledActor()).toBe(fixture.base.actor)
		expect(fixture.base.input.GetGraphSnapshot()).toBe(graph)
	end

	Utils.apply({ selection = { kind = "Set" } })
	expect(Runtime.GetControlledActor()).toBeNil()
end)

local malformed: { { name: string, value: unknown, reason: string } } = {
	{ name = "non-table", value = false, reason = "InvalidControlChangeSet" },
	{ name = "unknown top-level field", value = { actors = {} }, reason = "InvalidControlChangeSet" },
	{ name = "callback transaction", value = function() end, reason = "InvalidControlChangeSet" },
	{ name = "metatable", value = setmetatable({}, {}), reason = "InvalidControlChangeSet" },
	{ name = "non-array inputs", value = { inputs = { Core = {} } }, reason = "InvalidControlChangeSet" },
	{
		name = "sparse inputs",
		value = { inputs = { [2] = { kind = "Remove", sourceId = "Core" } } },
		reason = "InvalidControlChangeSet",
	},
	{
		name = "unknown input kind",
		value = { inputs = { { kind = "Patch", sourceId = "Core" } } },
		reason = "InvalidControlChangeSet",
	},
	{
		name = "missing Set definition",
		value = { inputs = { { kind = "Set", sourceId = "Core" } } },
		reason = "InvalidControlChangeSet",
	},
	{
		name = "Remove with definition",
		value = { inputs = { { kind = "Remove", sourceId = "Core", definition = {} } } },
		reason = "InvalidControlChangeSet",
	},
	{
		name = "unknown input field",
		value = { inputs = { { kind = "Remove", sourceId = "Core", extra = true } } },
		reason = "InvalidControlChangeSet",
	},
	{
		name = "empty source ID",
		value = { inputs = { { kind = "Remove", sourceId = "" } } },
		reason = "InvalidSourceId",
	},
	{
		name = "numeric source ID",
		value = { inputs = { { kind = "Remove", sourceId = 1 } } },
		reason = "InvalidSourceId",
	},
	{ name = "non-array profiles", value = { profiles = false }, reason = "InvalidControlChangeSet" },
	{
		name = "missing profile Actor",
		value = { profiles = { { kind = "Remove", sourceId = "Base" } } },
		reason = "InvalidControlChangeSet",
	},
	{
		name = "missing Set profile",
		value = { profiles = { { kind = "Set", actor = {}, sourceId = "Base" } } },
		reason = "InvalidControlChangeSet",
	},
	{
		name = "Remove with profile",
		value = { profiles = { { kind = "Remove", actor = {}, sourceId = "Base", profile = {} } } },
		reason = "InvalidControlChangeSet",
	},
	{
		name = "unknown profile kind",
		value = { profiles = { { kind = "Patch", actor = {}, sourceId = "Base" } } },
		reason = "InvalidControlChangeSet",
	},
	{ name = "non-array contexts", value = { contexts = "Combat" }, reason = "InvalidControlChangeSet" },
	{
		name = "missing enabled",
		value = { contexts = { { contextId = "Combat" } } },
		reason = "InvalidControlChangeSet",
	},
	{
		name = "non-Bool enabled",
		value = { contexts = { { contextId = "Combat", enabled = 1 } } },
		reason = "InvalidControlChangeSet",
	},
	{
		name = "unknown context field",
		value = { contexts = { { contextId = "Combat", enabled = true, priority = 5 } } },
		reason = "InvalidControlChangeSet",
	},
	{ name = "untagged selection", value = { selection = {} }, reason = "InvalidControlChangeSet" },
	{ name = "wrong selection kind", value = { selection = { kind = "Remove" } }, reason = "InvalidControlChangeSet" },
	{
		name = "unknown selection field",
		value = { selection = { kind = "Set", actors = {} } },
		reason = "InvalidControlChangeSet",
	},
}

table.insert(malformed, {
	name = "non-table profile Actor",
	value = { profiles = { { kind = "Remove", actor = 5, sourceId = "Base" } } },
	reason = "ActorViewUnavailable",
})

table.insert(malformed, {
	name = "invalid profile source key",
	value = { profiles = { { kind = "Remove", actor = {}, sourceId = 5 } } },
	reason = "InvalidProfileSourceId",
})

table.insert(malformed, {
	name = "non-table selection Actor",
	value = { selection = { kind = "Set", actor = false } },
	reason = "ActorViewUnavailable",
})

local oversized: { unknown } = {}

for index = 1, 257 do
	table.insert(oversized, { kind = "Remove", sourceId = "Unused" .. index })
end

table.insert(
	malformed,
	{ name = "unbounded operation array", value = { inputs = oversized }, reason = "InvalidControlChangeSet" }
)

for _, case in malformed do
	it("rejects " .. case.name .. " before writes, callbacks, epoch changes or selection", function()
		local original: number = Utils.charge(fixture)
		local graph = fixture.base.input.GetGraphSnapshot()
		local writes: number = #fixture.writes
		expect({ Controls.Apply((case.value :: unknown) :: Types.ControlChangeSet) }).toEqual({ false, case.reason })
		expect(fixture.base.input.GetGraphSnapshot()).toBe(graph)
		expect(#fixture.writes).toBe(writes)
		expect(Runtime.GetControlledActor()).toBe(fixture.base.actor)
		expect(Utils.kinds(fixture)).toEqual({ "KRF.Action.Start" })
		ActionUtils.emit(fixture.base, "Released")

		expect(ActionUtils.packets(fixture.base)[2]).toMatchObject({
			kind = "KRF.Action.Stop",
			originalStartRequestId = original,
		})
	end)
end

for _, reversed: boolean in { false, true } do
	it("rejects duplicate input owner keys regardless of Set/Remove order " .. tostring(reversed), function()
		local changes: { Types.InputSourceChange } = {
			{ kind = "Set", sourceId = "New", definition = {} },
			{ kind = "Remove", sourceId = "New" },
		}

		if reversed then
			changes[1], changes[2] = changes[2], changes[1]
		end

		local writes: number = #fixture.writes
		expect({ Controls.Apply({ inputs = changes }) }).toEqual({ false, "DuplicateInputSourceChange" })
		expect(#fixture.writes).toBe(writes)
	end)
end

it("rejects repeated Actor/source pairs and repeated context IDs without sequential semantics", function()
	expect({
		Controls.Apply({
			profiles = {
				{ kind = "Remove", actor = fixture.base.actor, sourceId = "Base" },
				{ kind = "Set", actor = fixture.base.actor, sourceId = "Base", profile = { routes = {} } },
			},
		}),
	}).toEqual({ false, "DuplicateProfileSourceChange" })

	expect({
		Controls.Apply({
			contexts = {
				{ contextId = "Combat", enabled = false },
				{ contextId = "Combat", enabled = true },
			},
		}),
	}).toEqual({ false, "DuplicateContextChange" })

	expect(fixture.base.input.GetContext("Combat")).toMatchObject({ enabled = true })
end)

it("accepts the same source string in independent Input and per-Actor profile namespaces", function()
	Utils.apply({
		inputs = { { kind = "Set", sourceId = "Shared", definition = {} } },
		profiles = {
			{
				kind = "Set",
				actor = fixture.base.actor,
				sourceId = "Shared",
				profile = { routes = { ActionUtils.route("Combat.Fireball") } },
			},
			{
				kind = "Set",
				actor = fixture.base.other,
				sourceId = "Shared",
				profile = { routes = { ActionUtils.route("Movement.Sprint") } },
			},
		},
	})

	Utils.apply({ inputs = { { kind = "Remove", sourceId = "Shared" } } })
	expect(Utils.route(fixture)).toMatchObject({ actionId = "Combat.Fireball", sourceId = "Shared" })
	expect(Utils.route(fixture, fixture.base.other)).toMatchObject({ actionId = "Movement.Sprint", sourceId = "Shared" })
end)

it("copies the complete declaration before a native callback can mutate the caller's tables", function()
	local definition = Utils.manual()
	local route: ActionTypes.ActionRoute = ActionUtils.route("Combat.Fireball", ActionUtils.key("Sign"))

	local changes: Types.ControlChangeSet = {
		inputs = { { kind = "Set", sourceId = "Manual", definition = definition } },
		profiles = {
			{ kind = "Set", actor = fixture.base.actor, sourceId = "Manual", profile = { routes = { route } } },
		},
		contexts = { { contextId = "HandSigns", enabled = true } },
	}

	fixture.onWrite = function(): ()
		fixture.onWrite = nil
		assert(definition.contexts).HandSigns.priority = 1
		assert(definition.inputs).Sign.bindings.Keyboard.keyCode = Enum.KeyCode.E
		route.target = { kind = "Fixed", actionId = "Movement.Sprint" }
		assert(changes.contexts)[1].enabled = false
	end

	Utils.apply(changes)
	expect(fixture.base.input.GetContext("HandSigns")).toMatchObject({ priority = 3000, enabled = true })
	expect(assert(fixture.base.input.GetEffectiveBindings("Sign")).Keyboard.definition.keyCode).toBe(Enum.KeyCode.Q)

	expect(Runtime.GetEffectiveRoute(fixture.base.actor, ActionUtils.key("Sign"))).toMatchObject({
		actionId = "Combat.Fireball",
	})
end)

for _, field: string in { "inputs", "profiles", "contexts" } do
	it("returns the same reason for reordered invalid " .. field .. " operations", function()
		local operations: { unknown } = {}
		local reason: string

		if field == "inputs" then
			table.insert(operations, { kind = "Remove", sourceId = "" })
			table.insert(operations, { kind = "Patch", sourceId = "Other" })
			reason = "InvalidControlChangeSet"
		elseif field == "profiles" then
			table.insert(operations, { kind = "Remove", actor = false, sourceId = "Base" })
			table.insert(operations, { kind = "Set", actor = fixture.base.actor, sourceId = "Other" })

			reason = "ActorViewUnavailable"
		else
			table.insert(operations, { contextId = "Combat", enabled = false })
			table.insert(operations, { contextId = "Combat", enabled = true })
			table.insert(operations, { contextId = "Other", enabled = "invalid" })

			reason = "DuplicateContextChange"
		end

		local graph = fixture.base.input.GetGraphSnapshot()
		local writes: number = #fixture.writes

		for _ = 1, #operations do
			local change: Types.ControlChangeSet = ({ [field] = operations } :: unknown) :: Types.ControlChangeSet

			expect({ Controls.Apply(change) }).toEqual({ false, reason })
			table.insert(operations, table.remove(operations, 1))
		end

		expect(fixture.base.input.GetGraphSnapshot()).toBe(graph)
		expect(#fixture.writes).toBe(writes)
	end)
end

it("returns the same profile compiler cause across reordered Actor contributions", function()
	local missingContext: ActionTypes.ActionRoute = ActionUtils.route("Combat.Fireball")
	missingContext.requiredContexts = { "Missing" }

	local operations: { Types.ProfileSourceChange } = {
		{
			kind = "Set",
			actor = fixture.base.actor,
			sourceId = "Same",
			profile = { routes = { ActionUtils.route("Combat.Fireball", ActionUtils.key("Missing")) } },
		},
		{
			kind = "Set",
			actor = fixture.base.other,
			sourceId = "Same",
			profile = { routes = { missingContext } },
		},
	}

	local graph = fixture.base.input.GetGraphSnapshot()
	local writes: number = #fixture.writes

	for _ = 1, 2 do
		expect({ Controls.Apply({ profiles = operations }) }).toEqual({ false, "UnknownRouteContext" })
		operations[1], operations[2] = operations[2], operations[1]
	end

	expect(fixture.base.input.GetGraphSnapshot()).toBe(graph)
	expect(#fixture.writes).toBe(writes)
	expect(Runtime.GetProfileSources(fixture.base.other)).toEqual({})
end)
