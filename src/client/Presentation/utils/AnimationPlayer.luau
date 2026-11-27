--!strict
local Types = require(script.Parent.Parent.types)
local Validator = require(script.Parent.Parent.AnimationPlayValidator)

local AnimationPlayer = {}

local function controllerOf(model: Model): (Humanoid | AnimationController)?
	local humanoid: Humanoid? = model:FindFirstChildOfClass("Humanoid")

	if humanoid ~= nil then
		return humanoid
	end

	return model:FindFirstChildOfClass("AnimationController")
end

local function createAnimator(controller: Instance): Animator
	local animator: Animator = Instance.new("Animator")
	animator.Parent = controller

	return animator
end

function AnimationPlayer.new(cache: Types.AnimationTrackCache): Types.AnimationsModule
	local function play(
		model: Model,
		animationId: string,
		options: Types.AnimationPlayOptions?
	): (Types.AnimationPlayback?, string?)
		if typeof(model) ~= "Instance" or not model:IsA("Model") then
			return nil, "AnimationModelInvalid"
		end

		local normalized: string?, idReason: string? = Validator.AnimationId(animationId)

		if normalized == nil then
			return nil, idReason
		end

		local compiled: Types.CompiledAnimationPlayOptions?, optionsReason: string? = Validator.Options(options)

		if compiled == nil then
			return nil, optionsReason
		elseif model:FindFirstAncestorWhichIsA("WorldRoot") == nil then
			return nil, "AnimationModelNotInWorld"
		end

		local controller: (Humanoid | AnimationController)? = controllerOf(model)

		if controller == nil then
			return nil, "AnimationRigMissing"
		end

		local existing: Animator? = controller:FindFirstChildOfClass("Animator")
		local created: boolean = existing == nil
		local animator: Animator = if existing ~= nil then existing else createAnimator(controller)
		local rig: Types.AnimationRig = { model = model, controller = controller, animator = animator }
		local playback: Types.AnimationPlayback?, reason: string? = cache:Play(rig, normalized, compiled)

		if playback == nil and created and not cache:Holds(animator) then
			animator:Destroy()
		end

		return playback, reason
	end

	return table.freeze({ Play = play })
end

return table.freeze(AnimationPlayer)
