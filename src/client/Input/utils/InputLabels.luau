--!strict
export type Association = { inputId: string, action: InputAction, disconnect: RBXScriptConnection }

export type Owner = {
	Bind: (inputId: string, label: InputActionLabel, action: InputAction) -> (),
	Unbind: (label: InputActionLabel) -> (),
	Reconcile: (actions: { [string]: InputAction }) -> (),
	Destroy: () -> (),
}

local Labels = {}

function Labels.new(): Owner
	local associations: { [InputActionLabel]: Association } = {}

	local function unbind(label: InputActionLabel): ()
		local association: Association? = associations[label]

		if association == nil then
			return
		end

		associations[label] = nil
		association.disconnect:Disconnect()

		if label.InputAction == association.action then
			label.InputAction = nil :: any
		end
	end

	return {
		Bind = function(inputId: string, label: InputActionLabel, action: InputAction): ()
			unbind(label)
			label.InputAction = action

			associations[label] = {
				inputId = inputId,
				action = action,
				disconnect = label.Destroying:Connect(function(): ()
					unbind(label)
				end),
			}
		end,
		Unbind = unbind,
		Reconcile = function(actions: { [string]: InputAction }): ()
			for label: InputActionLabel, association: Association in table.clone(associations) do
				local action: InputAction? = actions[association.inputId]

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
