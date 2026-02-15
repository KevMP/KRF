--!strict
local Types = require(script.Parent.types)

export type ActorRegistry = Types.ActorRegistry
export type Actor = Types.Actor
type ActorBindingRecord = {
	actor: Actor,
	model: Model,
	modelGoneFired: boolean,
	connections: { RBXScriptConnection },
}

local ActorRegistry = {} :: ActorRegistry
local byId: { [string]: ActorBindingRecord } = {}
local byModel: { [Model]: ActorBindingRecord } = {}

function cleanUpActorBindingRecord(bindingRecord: ActorBindingRecord)
	local actor: Actor = bindingRecord.actor
	local actorId: string = actor:GetId()

	if byId[actorId] == bindingRecord then
		byId[actorId] = nil
	end

	if byModel[bindingRecord.model] == bindingRecord then
		byModel[bindingRecord.model] = nil
	end

	if actor.model == bindingRecord.model then
		actor.model = nil
	end

	for _, conn: RBXScriptConnection in bindingRecord.connections do
		conn:Disconnect()
	end

	table.clear(bindingRecord.connections)
end

local modelGoneHandler: ((Actor, string) -> ())? = nil

local function handleModelGone(bindingRecord: ActorBindingRecord)
	if bindingRecord.modelGoneFired then
		return
	end
	bindingRecord.modelGoneFired = true

	if modelGoneHandler then
		local ok: boolean, err: any = pcall(modelGoneHandler, bindingRecord.actor, "ModelGone")
		if not ok then
			warn("ModelGone handler failed: ", err)
			cleanUpActorBindingRecord(bindingRecord) --fallback guarantee
		end
	else
		cleanUpActorBindingRecord(bindingRecord)
	end
end

function ActorRegistry.SetModelGoneHandler(handler: ((Actor, string) -> ())?)
	modelGoneHandler = handler
end

function ActorRegistry.GetActorById(actorId: string): Actor?
	local actorRecord: ActorBindingRecord? = byId[actorId]
	if actorRecord then
		return actorRecord.actor
	else
		return nil
	end
end

function ActorRegistry.GetActorByModel(actorModel: Model): Actor?
	local actorRecord: ActorBindingRecord? = byModel[actorModel]
	if actorRecord then
		return actorRecord.actor
	else
		return nil
	end
end

function ActorRegistry.BindModel(actor: Actor, model: Model): (boolean, string?)
	local existing: Actor? = ActorRegistry.GetActorByModel(model)
	local actorId: string = actor:GetId()
	if existing then
		warn(
			("[ActorRegistry] BindModel failed: reason=ModelAlreadyRegistered model=%s boundActorId=%s attemptedActorId=%s"):format(
				model:GetFullName(),
				existing:GetId(),
				actorId
			)
		)
		return false, "ModelAlreadyRegistered"
	end

	if actor.model ~= nil then
		warn(
			("[ActorRegistry] BindModel failed: reason=ActorHasDifferentModelBinded actorId=%s currentModel=%s attemptedModel=%s"):format(
				actorId,
				actor.model and actor.model:GetFullName() or "<nil>",
				model:GetFullName()
			)
		)
		return false, "ActorHasDifferentModelBinded"
	end

	local existingBindingRecord: ActorBindingRecord? = byId[actorId]
	local bindingRecord: ActorBindingRecord

	if existingBindingRecord ~= nil then
		bindingRecord = existingBindingRecord
	else
		local newRecord: ActorBindingRecord = {
			actor = actor,
			model = model,
			modelGoneFired = false,
			connections = {},
		}
		bindingRecord = newRecord
	end

	byId[actorId] = bindingRecord
	byModel[model] = bindingRecord
	actor.model = model

	local destroyingConn: RBXScriptConnection = model.Destroying:Connect(function()
		--here we want to call some sort of opts.ModelDestrying which will call unbind, if no opts then proceed with calling cleanupactorbinding record
		handleModelGone(bindingRecord)
	end)

	local ancestryChangedConn: RBXScriptConnection = model:GetPropertyChangedSignal("Parent"):Connect(function()
		if model.Parent == nil then
			handleModelGone(bindingRecord)
		end
	end)

	table.insert(bindingRecord.connections, destroyingConn)
	table.insert(bindingRecord.connections, ancestryChangedConn)

	return true, nil
end

function ActorRegistry.UnbindModel(actor: Actor): boolean
	local record: ActorBindingRecord? = byId[actor:GetId()]
	if not record then
		return false
	end

	cleanUpActorBindingRecord(record)
	return true
end

return ActorRegistry
