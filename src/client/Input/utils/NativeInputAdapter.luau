--!strict
local Players = game:GetService("Players")
local Types = require(script.Parent.Parent.types)

local Native = {}

function Native.new(): Types.NativeInputAdapter
	local container: Folder? = nil

	local function getContainer(): Folder
		if container == nil then
			local player: Player? = Players.LocalPlayer
			assert(player ~= nil, "LocalPlayerUnavailable")
			local scripts: Instance? = player:FindFirstChild("PlayerScripts")
			assert(scripts ~= nil, "PlayerScriptsUnavailable")

			local folder: Folder = Instance.new("Folder")
			folder.Name = "KRFInputs"
			folder.Parent = scripts
			container = folder
		end

		return container :: Folder
	end

	return {
		CreateContext = function(id: string, definition: Types.ContextDefinition): InputContext
			local context: InputContext = Instance.new("InputContext")
			context.Name = id
			context.Enabled = false
			context.Priority = definition.priority
			context.Sink = definition.sink
			context.Parent = getContainer()

			return context
		end,
		ConfigureContext = function(context: InputContext, definition: Types.ContextDefinition, enabled: boolean): ()
			context.Priority = definition.priority
			context.Sink = definition.sink
			context.Enabled = enabled
		end,
		CreateAction = function(id: string, definition: Types.InputDefinition, context: InputContext): InputAction
			local action: InputAction = Instance.new("InputAction")
			action.Name = id
			action.Type = definition.type
			action.DisplayName = definition.displayName or id
			action.Parent = context

			return action
		end,
		CreateBinding = function(slot: string, definition: Types.BindingDefinition, action: InputAction): InputBinding
			local binding: InputBinding = Instance.new("InputBinding")
			binding.Name = slot
			binding.Type = Enum.InputBindingType.Automatic

			if definition.keyCode ~= nil then
				binding.KeyCode = definition.keyCode
			end

			if definition.forward ~= nil then
				binding.Forward = definition.forward
			end

			if definition.backward ~= nil then
				binding.Backward = definition.backward
			end

			if definition.left ~= nil then
				binding.Left = definition.left
			end

			if definition.right ~= nil then
				binding.Right = definition.right
			end

			if definition.up ~= nil then
				binding.Up = definition.up
			end

			if definition.down ~= nil then
				binding.Down = definition.down
			end

			if definition.primaryModifier ~= nil then
				binding.PrimaryModifier = definition.primaryModifier
			end

			if definition.secondaryModifier ~= nil then
				binding.SecondaryModifier = definition.secondaryModifier
			end

			if definition.pressedThreshold ~= nil then
				binding.PressedThreshold = definition.pressedThreshold
			end

			if definition.releasedThreshold ~= nil then
				binding.ReleasedThreshold = definition.releasedThreshold
			end

			if definition.scale ~= nil then
				binding.Scale = definition.scale
			end

			if definition.vector2Scale ~= nil then
				binding.Vector2Scale = definition.vector2Scale
			end

			if definition.vector3Scale ~= nil then
				binding.Vector3Scale = definition.vector3Scale
			end

			if definition.responseCurve ~= nil then
				binding.ResponseCurve = definition.responseCurve
			end

			if definition.clampMagnitudeToOne ~= nil then
				binding.ClampMagnitudeToOne = definition.clampMagnitudeToOne
			end

			if definition.pointerIndex ~= nil then
				binding.PointerIndex = definition.pointerIndex
			end

			if definition.uiButton ~= nil then
				binding.UIButton = definition.uiButton
			end

			if definition.uiModifier ~= nil then
				binding.UIModifier = definition.uiModifier
			end

			if definition.displayName ~= nil then
				binding.DisplayName = definition.displayName
			end

			if definition.displayImage ~= nil then
				binding.DisplayImage = definition.displayImage
			end

			binding.Parent = action

			return binding
		end,
		ObserveAction = function(action: InputAction, callback: (Types.NativeTransition, any) -> ()): () -> ()
			local pressed: RBXScriptConnection = action.Pressed:Connect(function(): ()
				callback("Pressed", true)
			end)

			local released: RBXScriptConnection = action.Released:Connect(function(): ()
				callback("Released", false)
			end)

			local changed: RBXScriptConnection = action.StateChanged:Connect(function(value: any): ()
				callback("StateChanged", value)
			end)

			return function(): ()
				pressed:Disconnect()
				released:Disconnect()
				changed:Disconnect()
			end
		end,
		ReadState = function(action: InputAction): any
			return action:GetState()
		end,
		Destroy = function(instance: Instance): ()
			instance:Destroy()
		end,
		DestroyContainer = function(): ()
			if container ~= nil then
				container:Destroy()
				container = nil
			end
		end,
	}
end

return Native
