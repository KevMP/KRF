--!strict
local Types = require(script.Parent.Parent.types)

local VISIT_LIMIT: number = 2048
local TARGET_LIMIT: number = 256

local CONTENT_CLASSES: { string } = table.freeze({
	"Animation",
	"Sound",
	"ParticleEmitter",
	"Beam",
	"Trail",
	"Decal",
	"MeshPart",
	"SpecialMesh",
	"ImageLabel",
	"ImageButton",
	"Sky",
})

local AssetPreloadTargets = {}

local function bearsContent(instance: Instance): boolean
	for _, className: string in CONTENT_CLASSES do
		if instance:IsA(className) then
			return true
		end
	end

	return false
end

local function materialize(descriptor: Types.PreloadDescriptor): Instance
	if descriptor.kind == "Animation" then
		local animation: Animation = Instance.new("Animation")
		animation.AnimationId = descriptor.assetId

		return animation
	end

	local sound: Sound = Instance.new("Sound")
	sound.SoundId = descriptor.assetId

	return sound
end

local function collectSelected(instances: { Instance }, room: number): ({ Instance }?, string?)
	local targets: { Instance } = {}
	local pending: { Instance } = {}
	local scheduled: { [Instance]: boolean } = {}
	local visits: number = 0

	local function schedule(instance: Instance): boolean
		if scheduled[instance] then
			return true
		end

		visits += 1

		if visits > VISIT_LIMIT then
			return false
		end

		scheduled[instance] = true
		table.insert(pending, instance)

		return true
	end

	for index = #instances, 1, -1 do
		if not schedule(instances[index]) then
			return nil, "PreloadDescendantLimit"
		end
	end

	while #pending > 0 do
		local instance: Instance = table.remove(pending) :: Instance

		if bearsContent(instance) then
			if #targets >= room then
				return nil, "PreloadTargetLimit"
			end

			table.insert(targets, instance)
		end

		local children: { Instance } = instance:GetChildren()

		for index = #children, 1, -1 do
			if not schedule(children[index]) then
				return nil, "PreloadDescendantLimit"
			end
		end
	end

	return targets, nil
end

function AssetPreloadTargets.Collect(
	request: Types.CompiledPreloadRequest,
	temporaries: { Instance }
): ({ Instance }?, string?)
	local targets: { Instance }?, reason: string? =
		collectSelected(request.instances, TARGET_LIMIT - #request.descriptors)

	if targets == nil then
		return nil, reason
	end

	local collected: { Instance } = targets :: { Instance }

	for _, descriptor: Types.PreloadDescriptor in request.descriptors do
		local temporary: Instance = materialize(descriptor)

		table.insert(temporaries, temporary)
		table.insert(collected, temporary)
	end

	return collected, nil
end

function AssetPreloadTargets.Release(temporaries: { Instance }): ()
	for _, temporary: Instance in temporaries do
		temporary:Destroy()
	end

	table.clear(temporaries)
end

return table.freeze(AssetPreloadTargets)
