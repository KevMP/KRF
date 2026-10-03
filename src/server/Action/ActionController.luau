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
	local effectiveById: GrantSet = {}
	local grantedActionIds: { string } = {}
	for _, definition: LoadedActionDefinition in catalog do
		if definition.autoGrant then
			effectiveById[definition.id] = true
			table.insert(grantedActionIds, definition.id)
		end
	end
	table.freeze(grantedActionIds)

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

		local nextEffective: GrantSet = {}
		for _, definition: LoadedActionDefinition in catalog do
			if definition.autoGrant then
				nextEffective[definition.id] = true
			end
		end
		for existingSourceId: string, grants: GrantSet in explicitBySourceId do
			if existingSourceId ~= sourceId then
				for actionId: string in grants do
					nextEffective[actionId] = true
				end
			end
		end
		for actionId: string in replacement do
			nextEffective[actionId] = true
		end

		local previousEffective: GrantSet = effectiveById
		local nextGrantedActionIds: { string } = {}
		local transitions: { GrantTransition } = {}
		for _, definition: LoadedActionDefinition in catalog do
			local actionId: string = definition.id
			local isGranted: boolean = nextEffective[actionId] == true
			if isGranted then
				table.insert(nextGrantedActionIds, actionId)
			end
			if (previousEffective[actionId] == true) ~= isGranted then
				table.insert(transitions, { actionId = actionId, isGranted = isGranted })
			end
		end

		if next(replacement) == nil then
			explicitBySourceId[sourceId] = nil
		else
			explicitBySourceId[sourceId] = replacement
		end
		effectiveById = nextEffective
		grantedActionIds = table.freeze(nextGrantedActionIds)

		ownedSignals:WithDeferredDestroy(function()
			for _, transition: GrantTransition in transitions do
				grantChangedSignal:Fire(actor, transition.actionId, transition.isGranted)
			end
		end)

		return true, nil
	end

	function controller:IsActionGranted(actionId: string): boolean
		return effectiveById[actionId] == true
	end

	function controller:GetGrantedActions(): { string }
		return grantedActionIds
	end

	function controller:Destroy(): ()
		if destroyed then
			return
		end
		destroyed = true
		table.clear(explicitBySourceId)
		table.clear(effectiveById)
		local emptyGrantedActionIds: { string } = {}
		grantedActionIds = table.freeze(emptyGrantedActionIds)
		ownedSignals:Destroy()
	end

	controller.OnActionGrantChanged = SignalModule.wrapEvent(grantChangedSignal)
	return controller
end

return ActionControllerModule
