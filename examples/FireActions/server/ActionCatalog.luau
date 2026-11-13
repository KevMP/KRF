--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KRF = ReplicatedStorage.Packages.KRF
local Types = require(KRF.server.Action.types)
local ActorTypes = require(KRF.server.Actor.types)
local TagTypes = require(KRF.server.Tags.types)

local Catalog = {}

local function root(actor: ActorTypes.Actor?): BasePart?
	local part: Instance? = if actor ~= nil
			and actor.enabled
			and actor.model ~= nil
		then actor.model:FindFirstChild("HumanoidRootPart")
		else nil

	return if part ~= nil and part:IsA("BasePart") then part else nil
end

local function shape(folder: Folder, name: string, size: Vector3, color: Color3): Part
	local part: Part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Size = size
	part.Transparency = 0.4
	part.Parent = folder

	return part
end

function Catalog.Create(target: () -> ActorTypes.Actor?, effects: Folder): { Types.ActionFactory }
	local function canStart(context: Types.ActionStartContext): (boolean, string?)
		local origin: BasePart? = root(context.actor)
		local destination: BasePart? = root(target())

		if origin == nil or destination == nil then
			return false, "DemoTargetUnavailable"
		elseif (destination.Position - origin.Position).Magnitude > 40 then
			return false, "DemoTargetOutOfRange"
		end

		return true, nil
	end

	local function hit(stun: boolean): ()
		local actor: ActorTypes.Actor? = target()

		if actor ~= nil and root(actor) ~= nil then
			local tags: TagTypes.TagController = assert(actor:GetController("TagController")) :: TagTypes.TagController
			assert(tags:AddTag("Burning"))

			if stun then
				assert(tags:AddTag("Stunned"))
			end
		end
	end

	local function fireBreath(): Types.ActionDefinition
		local beam: Part? = nil
		local pulse: number = 0

		local function cleanup(): ()
			if beam ~= nil then
				beam:Destroy()
				beam = nil
			end
		end

		return {
			id = "Demo.FireBreath",
			visibility = "ClientVisible",
			locks = { "FireBreath" },
			blockedTags = { "Stunned" },
			activeTags = { "BreathingFire" },
			onCanStart = canStart,
			onStart = function(): ()
				beam = shape(effects, "FireBreath", Vector3.new(5, 3, 26), Color3.fromRGB(255, 110, 20))
			end,
			onUpdate = function(context: Types.ActionExecutionContext, deltaTime: number): ()
				local origin: BasePart? = root(context.actor)
				local destination: BasePart? = root(target())

				if origin == nil or destination == nil then
					context:Interrupt("DemoTargetUnavailable")

					return
				end

				local direction: Vector3 = origin.CFrame.LookVector
				local position: Vector3 = origin.Position + Vector3.new(0, 1, 0)
				assert(beam).CFrame = CFrame.lookAt(position + direction * 13, position + direction * 14)
				pulse += deltaTime

				if pulse >= 0.25 then
					pulse %= 0.25
					local offset: Vector3 = destination.Position - position
					local forward: number = offset:Dot(direction)

					if forward > 0 and forward <= 28 and (offset - direction * forward).Magnitude <= 5 then
						hit(false)
					end
				end
			end,
			onStopRequested = function(context: Types.ActionExecutionContext): ()
				context:End()
			end,
			onEnd = cleanup,
			onInterrupt = cleanup,
		}
	end

	local function fireball(): Types.ActionDefinition
		local projectile: Part? = nil
		local origin: Vector3 = Vector3.zero
		local destination: Vector3 = Vector3.zero
		local elapsed: number = 0

		local function cleanup(): ()
			if projectile ~= nil then
				projectile:Destroy()
				projectile = nil
			end
		end

		return {
			id = "Demo.Fireball",
			visibility = "ClientVisible",
			locks = { "Fireball" },
			blockedTags = { "Stunned" },
			onCanStart = canStart,
			onStart = function(context: Types.ActionExecutionContext): ()
				origin = assert(root(context.actor)).Position + Vector3.new(0, 1, 0)
				destination = assert(root(target())).Position
				projectile = shape(effects, "Fireball", Vector3.new(2, 2, 2), Color3.fromRGB(255, 70, 0))
				projectile.Shape = Enum.PartType.Ball
				projectile.Position = origin
			end,
			onUpdate = function(context: Types.ActionExecutionContext, deltaTime: number): ()
				elapsed += deltaTime
				assert(projectile).Position = origin:Lerp(destination, math.min(elapsed / 0.65, 1))

				if elapsed >= 0.65 then
					local current: BasePart? = root(target())

					if current ~= nil and (current.Position - destination).Magnitude <= 4 then
						hit(false)
					end

					context:End()
				end
			end,
			onEnd = cleanup,
			onInterrupt = cleanup,
		}
	end

	local function flameStrike(): Types.ActionDefinition
		local column: Part? = nil
		local elapsed: number = 0

		local function cleanup(): ()
			if column ~= nil then
				column:Destroy()
				column = nil
			end
		end

		return {
			id = "Demo.FlameStrike",
			visibility = "ClientVisible",
			locks = { "FlameStrike" },
			blockedTags = { "Stunned" },
			onCanStart = canStart,
			onStart = function(): ()
				column = shape(effects, "FlameStrike", Vector3.new(8, 10, 8), Color3.fromRGB(255, 200, 30))
				column.Position = assert(root(target())).Position + Vector3.new(0, 2, 0)
				hit(true)
			end,
			onUpdate = function(context: Types.ActionExecutionContext, deltaTime: number): ()
				elapsed += deltaTime

				if elapsed >= 0.5 then
					context:End()
				end
			end,
			onEnd = cleanup,
			onInterrupt = cleanup,
		}
	end

	return { fireBreath, fireball, flameStrike }
end

return Catalog
