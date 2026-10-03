--!strict
local ActionTypes = require(script.Parent.types)
local ActorTypes = require(script.Parent.Parent.Actor.types)
local SignalTypes = require(script.Parent.Parent.Parent.shared.Signal.types)
local SignalModule = require(script.Parent.Parent.Parent.shared.Signal.SignalModule)
local OwnedSignalsModule = require(script.Parent.Parent.Parent.shared.Signal.OwnedSignals)
local ActionRegistry = require(script.Parent.ActionRegistry)

type Actor = ActorTypes.Actor
type ActionController = ActionTypes.ActionController
type LoadedActionDefinition = ActionTypes.LoadedActionDefinition
type GrantSet = { [string]: boolean }
type GrantTransition = { actionId: string, isGranted: boolean }

local ActionControllerModule = {}

function ActionControllerModule.new(actor: Actor): ActionController
	assert(ActionRegistry.IsLoaded(), "ActionRegistryNotLoaded")

	local catalog: { LoadedActionDefinition } = ActionRegistry.GetAll()
	local explicitBySourceId: { [string]: GrantSet } = {}
	local explicitGrantCountById: { [string]: number } = {}
	local autoGrantedById: GrantSet = {}
	local effectiveById: GrantSet = {}
	local emptyGrantedActionIds: { string } = {}
	table.freeze(emptyGrantedActionIds)
	local grantedActionIds: { string } = emptyGrantedActionIds
	local grantSnapshotDirty: boolean = true
	for _, definition: LoadedActionDefinition in catalog do
		if definition.autoGrant then
			autoGrantedById[definition.id] = true
			effectiveById[definition.id] = true
		end
	end

	local grantChangedSignal: SignalTypes.Signal<Actor, string, boolean> = SignalModule.new()
	local ownedSignals: SignalTypes.OwnedSignals = OwnedSignalsModule.new({ grantChangedSignal })
	local destroyed: boolean = false
	local controller: ActionController = {} :: ActionController

	function controller:SetGrants(sourceId: string, actionIds: { string }): (boolean, string?)
		if destroyed then
			return false, "ActionControllerDestroyed"
		end
		if type(sourceId) ~= "string" then
			return false, "ActionGrantSourceIdMustBeString"
		end
		if sourceId == "" then
			return false, "ActionGrantSourceIdCannotBeEmpty"
		end
		if type(actionIds) ~= "table" then
			return false, "ActionGrantIdsMustBeTable"
		end

		local rawActionIds: any = actionIds
		local count: number = 0
		for key: number in rawActionIds do
			if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
				return false, "ActionGrantIdsMustBeArray"
			end
			count += 1
		end

		local replacement: GrantSet = {}
		for index: number = 1, count do
			local actionId: any = rawActionIds[index]
			if actionId == nil then
				return false, "ActionGrantIdsMustBeArray"
			end
			if type(actionId) ~= "string" then
				return false, "ActionGrantIdMustBeString"
			end
			if actionId == "" then
				return false, "ActionGrantIdCannotBeEmpty"
			end
			if ActionRegistry.Get(actionId) == nil then
				return false, "UnknownActionId:" .. actionId
			end
			replacement[actionId] = true
		end

		local previous: GrantSet = explicitBySourceId[sourceId] or {}
		local nextCountsById: { [string]: number } = {}
		for actionId: string in previous do
			if not replacement[actionId] then
				nextCountsById[actionId] = (explicitGrantCountById[actionId] or 0) - 1
			end
		end
		for actionId: string in replacement do
			if not previous[actionId] then
				nextCountsById[actionId] = (explicitGrantCountById[actionId] or 0) + 1
			end
		end
		if next(nextCountsById) == nil then
			return true, nil
		end

		local transitions: { GrantTransition } = {}
		for actionId: string, nextCount: number in nextCountsById do
			local isGranted: boolean = autoGrantedById[actionId] == true or nextCount > 0
			if (effectiveById[actionId] == true) ~= isGranted then
				table.insert(transitions, { actionId = actionId, isGranted = isGranted })
			end
		end

		if next(replacement) == nil then
			explicitBySourceId[sourceId] = nil
		else
			explicitBySourceId[sourceId] = replacement
		end
		for actionId: string, nextCount: number in nextCountsById do
			if nextCount == 0 then
				explicitGrantCountById[actionId] = nil
			else
				explicitGrantCountById[actionId] = nextCount
			end
		end
		for _, transition: GrantTransition in transitions do
			if transition.isGranted then
				effectiveById[transition.actionId] = true
			else
				effectiveById[transition.actionId] = nil
			end
		end
		if #transitions > 0 then
			grantSnapshotDirty = true
			ownedSignals:WithDeferredDestroy(function()
				for _, transition: GrantTransition in transitions do
					grantChangedSignal:Fire(actor, transition.actionId, transition.isGranted)
				end
			end)
		end

		return true, nil
	end

	function controller:IsActionGranted(actionId: string): boolean
		return effectiveById[actionId] == true
	end

	function controller:GetGrantedActions(): { string }
		if grantSnapshotDirty then
			local snapshot: { string } = {}
			for _, definition: LoadedActionDefinition in catalog do
				if effectiveById[definition.id] then
					table.insert(snapshot, definition.id)
				end
			end
			grantedActionIds = table.freeze(snapshot)
			grantSnapshotDirty = false
		end
		return grantedActionIds
	end

	function controller:Destroy(): ()
		if destroyed then
			return
		end
		destroyed = true
		table.clear(explicitBySourceId)
		table.clear(explicitGrantCountById)
		table.clear(autoGrantedById)
		table.clear(effectiveById)
		grantedActionIds = emptyGrantedActionIds
		grantSnapshotDirty = false
		ownedSignals:Destroy()
	end

	controller.OnActionGrantChanged = SignalModule.wrapEvent(grantChangedSignal)
	return controller
end

return ActionControllerModule
