--!strict
local HttpService = game:GetService("HttpService")
local Types = require(script.Parent.types)

export type Actor = Types.Actor
export type Controller = Types.Controller

local ActorEntity = {}
ActorEntity.__index = ActorEntity

function ActorEntity.new(model: Model?): Actor
	local controllers: { [string]: Controller } = {}
	local id: string = HttpService:GenerateGUID(false)

	local actor = setmetatable({ model = model, enabled = false }, ActorEntity)

	function actor:GetId(): string
		return id
	end

	function actor:SetController(key: string, controller: Controller): boolean
		if controllers[key] ~= nil then
			return false
		end
		controllers[key] = controller
		return true
	end

	function actor:GetControllerKeys(): { string }
		local keys: { string } = {}
		for key, _ in controllers do
			table.insert(keys, key)
		end
		return keys
	end

	function actor:GetController(key: string): Controller?
		return controllers[key]
	end

	function actor:RemoveController(key: string): Controller?
		local controller: Controller? = self:GetController(key)
		controllers[key] = nil
		return controller
	end

	return actor :: Actor
end

return ActorEntity
