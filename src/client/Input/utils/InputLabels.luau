--!strict
export type Association = { inputId: string, action: InputAction, disconnect: RBXScriptConnection }

export type Owner = {
	BindActionLabel: (string, InputActionLabel) -> (boolean, string?),
	UnbindActionLabel: (InputActionLabel) -> (boolean, string?),
	Reconcile: (actions: { [string]: InputAction }) -> (),
	Destroy: () -> (),
}

local Labels = {}

function Labels.new(unavailable: () -> string?, actions: () -> { [string]: InputAction }): Owner
	local associations: { [InputActionLabel]: Association } = {}

	local function unbind(label: InputActionLabel): ()
		local association: Association? = associations[label]

		if association == nil then
			return
		end

		associations[label] = nil
		association.disconnect:Disconnect()

		if label.InputAction == association.action then
			-- The native property is nullable despite its generated API annotation.
			((label :: unknown) :: { InputAction: InputAction? }).InputAction = nil
		end
	end

	return {
		BindActionLabel = function(inputId: string, label: InputActionLabel): (boolean, string?)
			local reason: string? = unavailable()

			if reason ~= nil then
				return false, reason
			end

			local action: InputAction? = actions()[inputId]

			if action == nil then
				return false, "UnknownInput"
			end

			if typeof(label) ~= "Instance" or not label:IsA("InputActionLabel") then
				return false, "InvalidInputActionLabel"
			end

			unbind(label)
			label.InputAction = action

			associations[label] = {
				inputId = inputId,
				action = action,
				disconnect = label.Destroying:Connect(function(): ()
					unbind(label)
				end),
			}

			return true, nil
		end,
		UnbindActionLabel = function(label: InputActionLabel): (boolean, string?)
			local reason: string? = unavailable()

			if reason ~= nil then
				return false, reason
			end

			if typeof(label) ~= "Instance" or not label:IsA("InputActionLabel") then
				return false, "InvalidInputActionLabel"
			end

			unbind(label)

			return true, nil
		end,
		Reconcile = function(nextActions: { [string]: InputAction }): ()
			for label: InputActionLabel, association: Association in table.clone(associations) do
				local action: InputAction? = nextActions[association.inputId]

				if label.InputAction ~= association.action or action == nil then
					unbind(label)
				else
					label.InputAction = action
					association.action = action
				end
			end
		end,
		Destroy = function(): ()
			for label in table.clone(associations) do
				unbind(label)
			end
		end,
	}
end

return Labels
