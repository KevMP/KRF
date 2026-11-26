--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local JestGlobals: any = require(ReplicatedStorage.DevPackages.JestGlobals)
local it: any = JestGlobals.it
local expect: any = JestGlobals.expect
local Types = require(KRF.client.Presentation.types)
local Events = require(KRF.client.Presentation.PresentationEvents)
local States = require(KRF.client.Presentation.PresentationStates)
local Registry = require(KRF.client.Presentation.PresentationRegistry)

local function create(_context: Types.PresentationContext): () end

it("exposes frozen singleton state descriptors for every Watch family", function()
	expect(table.isfrozen(States)).toBe(true)
	expect(table.isfrozen(States.Tag)).toBe(true)
	expect(table.isfrozen(States.Action)).toBe(true)
	expect(table.isfrozen(States.Resource)).toBe(true)
	expect(table.isfrozen(States.Actor)).toBe(true)
	expect(States.Tag.Active).toEqual({ source = "Tag", state = "Active" })
	expect(States.Action.Active).toEqual({ source = "Action", state = "Active" })
	expect(States.Resource.Current).toEqual({ source = "Resource", state = "Current" })
	expect(States.Actor.Model).toEqual({ source = "Actor", state = "Model" })

	for _, descriptor: any in { States.Tag.Active, States.Action.Active, States.Resource.Current, States.Actor.Model } do
		expect(table.isfrozen(descriptor)).toBe(true)
	end
end)

it("indexes live event and current-state definitions separately with owned frozen bindings", function()
	local tagEntry = { state = States.Tag.Active, id = "Burning" }

	local definitions: { Types.PresentationDefinition } = {
		{ id = "Aura", entry = tagEntry, create = create },
		{ id = "Loop", entry = { state = States.Action.Active, id = "Sword.Charge" }, create = create },
		{ id = "Burst", entry = { event = Events.Tag.Added, id = "Burning" }, create = create },
	}

	local catalog: Types.PresentationCatalog?, reason: string? = Registry.Prepare(definitions)
	expect(reason).toBeNil()
	assert(catalog ~= nil, "Expected a prepared catalog")
	expect(table.isfrozen(catalog)).toBe(true)
	expect(table.isfrozen(catalog.events)).toBe(true)
	expect(table.isfrozen(catalog.states)).toBe(true)
	local aura: Types.PresentationDefinition = catalog.states[States.Tag.Active]["Burning"][1]
	expect(aura.id).toBe("Aura")
	expect(aura.entry).never.toBe(tagEntry)
	expect(aura.entry).toEqual({ state = States.Tag.Active, id = "Burning" })
	expect(table.isfrozen(aura.entry)).toBe(true)
	expect(aura.create).toBe(create)
	expect(catalog.states[States.Action.Active]["Sword.Charge"][1].id).toBe("Loop")
	expect(catalog.events[Events.Tag.Added]["Burning"][1].id).toBe("Burst")
	expect(catalog.states[Events.Tag.Added :: any]).toBeNil()
	expect(catalog.events[States.Tag.Active :: any]).toBeNil()
end)

it("rejects fabricated, Watch-only, event and ambiguous state entries with stable reasons", function()
	local cases: { { entry: any, reason: string } } = {
		{
			entry = { state = { source = "Tag", state = "Active" }, id = "Burning" },
			reason = "PresentationEntryStateInvalid",
		},
		{ entry = { state = States.Resource.Current, id = "Mana" }, reason = "PresentationEntryStateInvalid" },
		{ entry = { state = States.Actor.Model, id = "Model" }, reason = "PresentationEntryStateInvalid" },
		{ entry = { state = Events.Tag.Added, id = "Burning" }, reason = "PresentationEntryStateInvalid" },
		{ entry = { event = States.Tag.Active, id = "Burning" }, reason = "PresentationEntryEventInvalid" },
		{ entry = { state = "Tag.Active", id = "Burning" }, reason = "PresentationEntryStateInvalid" },
		{ entry = { state = States.Tag.Active, id = "" }, reason = "PresentationEntryIdInvalid" },
		{ entry = { state = States.Tag.Active }, reason = "PresentationEntryIdInvalid" },
		{
			entry = { state = States.Tag.Active, event = Events.Tag.Added, id = "Burning" },
			reason = "PresentationEntryAmbiguous",
		},
		{ entry = { id = "Burning" }, reason = "PresentationEntryEventInvalid" },
		{
			entry = { state = States.Tag.Active, id = "Burning", scope = "Any" },
			reason = "PresentationEntryFieldUnknown",
		},
	}

	for _, case in cases do
		local catalog: Types.PresentationCatalog?, reason: string? =
			Registry.Prepare({ { id = "Aura", entry = case.entry, create = create } })

		expect(catalog).toBeNil()
		expect(reason).toBe(case.reason)
	end
end)

it("rejects a whole mixed batch when one state definition is invalid", function()
	local catalog: Types.PresentationCatalog?, reason: string? = Registry.Prepare({
		{ id = "Burst", entry = { event = Events.Tag.Added, id = "Burning" }, create = create },
		{ id = "Aura", entry = { state = States.Tag.Active, id = "Burning" }, create = create },
		{ id = "Mana", entry = { state = States.Resource.Current, id = "Mana" }, create = create },
	})

	expect(catalog).toBeNil()
	expect(reason).toBe("PresentationEntryStateInvalid")

	catalog, reason = Registry.Prepare({
		{ id = "Aura", entry = { state = States.Tag.Active, id = "Burning" }, create = create },
		{ id = "Aura", entry = { event = Events.Tag.Added, id = "Burning" }, create = create },
	})

	expect(catalog).toBeNil()
	expect(reason).toBe("PresentationIdDuplicate")
end)
