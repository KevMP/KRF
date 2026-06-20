--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local it = JestGlobals.it
local expect = JestGlobals.expect

local KRF = ReplicatedStorage.Packages.KRF

local ActorEntity = require(KRF.server.Actor.ActorEntity)
local TagRegistry = require(KRF.server.Tags.TagRegistry)
local PropertyControllerEventUtils = require(KRF.server.Property.utils.PropertyControllerEvent)
local PropertyModifierCollector = require(KRF.server.Property.utils.PropertyModifierCollector)
local PropertyRecompute = require(KRF.server.Property.utils.PropertyRecompute)
local SignalModule = require(KRF.shared.Signal.SignalModule)
local OwnedSignalsModule = require(KRF.shared.Signal.OwnedSignals)
local ActorTypes = require(KRF.server.Actor.types)
local PropertyTypes = require(KRF.server.Property.types)
local SignalTypes = require(KRF.shared.Signal.types)
local TagTypes = require(KRF.server.Tags.types)
local TagTestUtils: any = script.Parent.Parent.Parent.Utils.Tags

type Actor = ActorTypes.Actor
type PropertyChange = PropertyTypes.PropertyChange
type PropertyControllerEventContext = PropertyControllerEventUtils.PropertyControllerEventContext
type PropertyRecordsById = PropertyRecompute.PropertyRecordsById
type TagDefinition = TagTypes.TagDefinition

local MixedTagCatalog: { TagDefinition } = require(TagTestUtils.MixedTagCatalog) :: { TagDefinition }

local function loadMixedTagCatalog(): ()
	TagRegistry._resetForTests()

	local loaded: boolean, loadReason: string? = TagRegistry.Load(MixedTagCatalog)
	expect(loaded).toBe(true)
	expect(loadReason).toBeNil()
end

local function createEventContext(): (
	PropertyControllerEventContext,
	SignalTypes.Signal<Actor, string, number?, number>,
	SignalTypes.Signal<Actor, string, number?, number>,
	SignalTypes.Signal<PropertyChange>
)
	local actor: Actor = ActorEntity.new()
	local baseSignal: SignalTypes.Signal<Actor, string, number?, number> = SignalModule.new()
	local resolvedSignal: SignalTypes.Signal<Actor, string, number?, number> = SignalModule.new()
	local propertySignal: SignalTypes.Signal<PropertyChange> = SignalModule.new()
	local ownedSignals: SignalTypes.OwnedSignals = OwnedSignalsModule.new({
		baseSignal,
		resolvedSignal,
		propertySignal,
	})

	return {
		actor = actor,
		ownedSignals = ownedSignals,
		basePropertyChangedSignal = baseSignal,
		resolvedPropertyChangedSignal = resolvedSignal,
		propertyChangedSignal = propertySignal,
	},
		baseSignal,
		resolvedSignal,
		propertySignal
end

it("CollectForProperty returns empty without a tag controller and ignores unknown active tag ids", function()
	loadMixedTagCatalog()

	local noControllerEntries = PropertyModifierCollector.CollectForProperty(nil, "WalkSpeed")

	expect(noControllerEntries).toEqual({})

	local fakeTagController = {
		GetActiveTags = function()
			return {
				{
					tagId = "Status.Unknown",
					stackCount = 1,
				},
			}
		end,
	} :: any

	local unknownTagEntries = PropertyModifierCollector.CollectForProperty(fakeTagController, "WalkSpeed")

	expect(unknownTagEntries).toEqual({})
	expect(PropertyModifierCollector.GetAffectedPropertyNames("Status.Unknown")).toEqual({})
end)

it("RecomputeProperty returns nil for missing properties and unchanged resolutions", function()
	loadMixedTagCatalog()

	local missingPropertiesById: PropertyRecordsById = {}
	local missingChange = PropertyRecompute.RecomputeProperty(missingPropertiesById, nil, "Armor")

	expect(missingChange).toBeNil()

	local unchangedPropertiesById: PropertyRecordsById = {
		WalkSpeed = {
			baseValue = 0,
			resolvedValue = 0,
		},
	}
	local fakeTagController = {
		GetActiveTags = function()
			return {
				{
					tagId = "Status.Stunned",
					stackCount = 1,
				},
			}
		end,
	} :: any

	local unchangedChange = PropertyRecompute.RecomputeProperty(unchangedPropertiesById, fakeTagController, "WalkSpeed")

	expect(unchangedChange).toBeNil()
end)

it("RecomputePropertiesAffectedByTag skips unstored properties and unchanged recomputes", function()
	loadMixedTagCatalog()

	local propertiesById: PropertyRecordsById = {
		WalkSpeed = {
			baseValue = 16,
			resolvedValue = 16,
		},
	}
	local fakeTagController = {
		GetActiveTags = function()
			return {
				{
					tagId = "Buff.Sprint",
					stackCount = 1,
				},
			}
		end,
	} :: any

	local sprintChanges =
		PropertyRecompute.RecomputePropertiesAffectedByTag(propertiesById, fakeTagController, "Buff.Sprint")

	expect(#sprintChanges).toBe(1)
	expect(sprintChanges[1].propertyName).toBe("WalkSpeed")

	local unchangedPropertiesById: PropertyRecordsById = {
		WalkSpeed = {
			baseValue = 0,
			resolvedValue = 0,
		},
	}
	local stunnedTagController = {
		GetActiveTags = function()
			return {
				{
					tagId = "Status.Stunned",
					stackCount = 1,
				},
			}
		end,
	} :: any

	local stunnedChanges = PropertyRecompute.RecomputePropertiesAffectedByTag(
		unchangedPropertiesById,
		stunnedTagController,
		"Status.Stunned"
	)

	expect(stunnedChanges).toEqual({})
end)

it("FireResolvedChanges returns early for empty batches and stops before later changes when asked to stop", function()
	local eventContext: PropertyControllerEventContext, _baseSignal: SignalTypes.Signal<Actor, string, number?, number>, resolvedSignal: SignalTypes.Signal<Actor, string, number?, number>, propertySignal: SignalTypes.Signal<PropertyChange> =
		createEventContext()
	local resolvedEventCount: number = 0
	local propertyEventCount: number = 0
	local shouldContinue: boolean = true

	resolvedSignal:Connect(function()
		resolvedEventCount += 1
	end)
	propertySignal:Connect(function()
		propertyEventCount += 1
		shouldContinue = false
	end)

	PropertyControllerEventUtils.FireResolvedChanges(eventContext, {}, function(): boolean
		return true
	end)

	PropertyControllerEventUtils.FireResolvedChanges(eventContext, {
		{
			propertyName = "WalkSpeed",
			oldBaseValue = 16,
			newBaseValue = 16,
			oldResolvedValue = 16,
			newResolvedValue = 20,
		},
		{
			propertyName = "JumpPower",
			oldBaseValue = 50,
			newBaseValue = 50,
			oldResolvedValue = 50,
			newResolvedValue = 0,
		},
	}, function(): boolean
		return shouldContinue
	end)

	expect(resolvedEventCount).toBe(1)
	expect(propertyEventCount).toBe(1)
end)

it("FirePropertyChanged skips the resolved signal when only the base value should report", function()
	local eventContext: PropertyControllerEventContext, baseSignal: SignalTypes.Signal<Actor, string, number?, number>, resolvedSignal: SignalTypes.Signal<Actor, string, number?, number>, propertySignal: SignalTypes.Signal<PropertyChange> =
		createEventContext()
	local baseEvents: { { propertyName: string, oldValue: number?, newValue: number } } = {}
	local resolvedEventCount: number = 0
	local propertyChanges: { PropertyChange } = {}

	baseSignal:Connect(function(_actor: Actor, propertyName: string, oldValue: number?, newValue: number)
		table.insert(baseEvents, {
			propertyName = propertyName,
			oldValue = oldValue,
			newValue = newValue,
		})
	end)
	resolvedSignal:Connect(function()
		resolvedEventCount += 1
	end)
	propertySignal:Connect(function(change: PropertyChange)
		table.insert(propertyChanges, change)
	end)

	PropertyControllerEventUtils.FirePropertyChanged(eventContext, "WalkSpeed", 10, 16, 10, 10, true, false)

	expect(baseEvents).toEqual({
		{
			propertyName = "WalkSpeed",
			oldValue = 10,
			newValue = 16,
		},
	})
	expect(resolvedEventCount).toBe(0)
	expect(propertyChanges).toEqual({
		{
			actor = eventContext.actor,
			propertyName = "WalkSpeed",
			oldBaseValue = 10,
			newBaseValue = 16,
			oldResolvedValue = 10,
			newResolvedValue = 10,
		},
	})
end)
